require "line/bot"
require "net/http"
require "uri"
require "json"

class WebhookController < ApplicationController
  protect_from_forgery except: [:callback] # CSRF対策無効化
  JSON_BOX_ROOT_URL = "https://jsonbox.io/"
  HOW_TO_USE_MESSAGE = <<EOS
このBotではスラッシュコマンドを使うことで、個人チャット・トークルーム・グループごとに行きたいところリストを作成する事ができます。

【行きたいところリストに追加】
/追加 場所の名前

【行きたいところリストから削除】
/削除 場所の名前

【行きたいところリストから全て削除】
/全削除

【行きたいところリストを見る。】
/一覧

【使い方を見る】
/使い方
EOS

  def client
    @client ||= Line::Bot::Client.new { |config|
      config.channel_secret = ENV["LINE_CHANNEL_SECRET"]
      config.channel_token = ENV["LINE_CHANNEL_TOKEN"]
    }
  end

  def callback
    body = request.body.read

    signature = request.env["HTTP_X_LINE_SIGNATURE"]
    unless client.validate_signature(body, signature)
      head 470
    end

    events = client.parse_events_from(body)
    events.each do |event|
      source = event["source"]
      talk_id = source["groupId"] || source["roomId"] || source["userId"]

      case event
      when Line::Bot::Event::Message
        case event.type
        when Line::Bot::Event::MessageType::Text
          send_reply_to_text_message_handler(event.message["text"], talk_id, event["replyToken"])
        when Line::Bot::Event::MessageType::Image, Line::Bot::Event::MessageType::Video
          response = client.get_message_content(event.message["id"])
          tf = Tempfile.open("content")
          tf.write(response.body)
        end
      when Line::Bot::Event::Join
        send_text_message(event["replyToken"], "グループに招待ありがとうございます！\n" + HOW_TO_USE_MESSAGE)
      when Line::Bot::Event::Follow
        send_text_message(event["replyToken"], "友だち追加ありがとうございます！\n" + HOW_TO_USE_MESSAGE)
      end
    end
    head :ok
  end

  private

  def send_reply_to_text_message_handler(received_message, talk_id, reply_token)
    # TODO グループでない場合の処理
    case received_message
    when /^\/追加.+/u
      spot_name = received_message.sub(/\/追加/u, "").gsub(/　/, " ").strip
      logger.info "追加に入りました"
      save_to_jsonbox(spot_name, boxId: talk_id)
      text = "#{spot_name} を追加しました"
      # send_text_message(reply_token, text)
      send_template_message(reply_token, spot_name)
    when /^\/削除.+/u
      spot_name = received_message.sub(/\/削除/u, "").gsub(/　/, " ").strip
      logger.info "削除に入りました"
      remove_from_jsonbox(spot_name, boxId: talk_id)
      text = "#{spot_name} を削除しました"
    when /^\/全削除/
      logger.info "全削除に入りました"
      remove_from_jsonbox("*", boxId: talk_id)
      text = "リストから全てを削除しました"
    when /^\/一覧/
      logger.info "一覧に入りました"
      text = create_list_message(boxId: talk_id)
    when /^\/使い方/, /^\/つかいかた/
      logger.info "使い方に入りました"
      text = HOW_TO_USE_MESSAGE
    when /^\//
      logger.info "スラッシュエラーに入りました"
      text = "※コマンドが間違っています※\n" + HOW_TO_USE_MESSAGE
    else
      return
    end
    send_text_message(reply_token, text) #return text ->そとでsend
  end

  def send_template_message(reply_token, spotname)
    logger.debug("template")
    message = {
      "type": "text",
      "text": "#{spotname}を追加しました。",
      "quickReply": {
        "items": [
          {
            "type": "action",
            "action": {
              "type": "message",
              "label": "一覧をみる",
              "text": "/一覧",
            },
          },
          {
            "type": "action",
            "action": {
              "type": "message",
              "label": "取り消し",
              "text": "/削除 #{spotname}",
            },
          },
        ],
      },
    }
    response　 = client.reply_message(reply_token, message)
    logger.info "テンプレートメッセージを送信しました。: #{response}"
  end

  def send_text_message(reply_token, text)
    message = {
      type: "text",
      text: text,
      sender: {
        name: "StoreSpot",
      },
    }
    response　 = client.reply_message(reply_token, message)
    logger.info "メッセージを送信しました。: #{message[:text]}"
  end

  def remove_from_jsonbox(spot_name, boxId:)
    uri = build_box_uri(:boxId => boxId, :query_str => build_delete_query(spot_name))
    logger.debug uri
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    request = Net::HTTP::Delete.new(uri.request_uri)
    response = http.request(request)
    logger.info("id:#{boxId}から#{spot_name}をdeleteしました。#{response.body}")
  end

  def build_delete_query(spot_name)
    "?" + URI.encode("q=spotName:" + spot_name)
  end

  # @return 一覧の文字列
  def create_list_message(boxId:)
    convert_wants_list_to_text(load_from_jsonbox(boxId: boxId))
  end

  def load_from_jsonbox(boxId:)
    uri = build_box_uri(boxId: boxId)
    response = Net::HTTP.get_response(uri)
    spots_list = convert_to_json(response.body)
    logger.debug "jsonboxID: #{boxId} から: #{spots_list}を取得しました。#{response.code}"
    spots_list
  end

  # @param Hash
  def save_to_jsonbox(data, boxId:)
    uri = build_box_uri(boxId: boxId)
    http = Net::HTTP.new(uri.host, uri.port)
    params = { spotName: data }
    http.use_ssl = true
    headers = { "Content-Type" => "application/json" }
    http.post(uri.path, params.to_json, headers)
    logger.info("id:#{boxId}に#{params}をpostしました。")
  end

  def convert_wants_list_to_text(spots)
    text = "【行きたいところ一覧】"
    #TODO 0件のときの処理
    spots.each do |spot|
      text += "\n" + spot["spotName"]
    end
    text
  end

  def build_box_uri(boxId:, query_str: "")
    URI.parse(JSON_BOX_ROOT_URL + boxId + query_str)
  end

  def convert_to_json(str)
    JSON.parse(str)
  end
end
