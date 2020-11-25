require "line/bot"
require "net/http"
require "uri"
require "digest/md5"
require "json"

class WebhookController < ApplicationController
  protect_from_forgery except: [:callback] # CSRF対策無効化
  JSON_BOX_ROOT_URL = "https://jsonbox.io/"

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
      logger.debug "***********************************************************"
      case event
      when Line::Bot::Event::Message
        case event.type
        when Line::Bot::Event::MessageType::Text
          case event.message["text"]
          when /\/追加 .+/u
            spot_name = event.message["text"].sub(/\/追加/u, "")
            logger.info "追加に入りました"
            post_to_jsonbox(spot_name, boxId: event["source"]["roomId"])
            text = "#{spot_name} を追加しました"
          when /\/一覧/
            logger.info "一覧に入りました"
            text = get_list_message(boxId: event["source"]["roomId"])
          when /\/ランダム/, /\/お店/, /\/見る/
            #todo
          else
            text = "オウム返し！ ： " + event.message["text"]
          end
          message = {
            type: "text",
            text: text,
          }
          response　 = client.reply_message(event["replyToken"], message)
          logger.info "メッセージを送信しました。: #{message[:text]}"
        when Line::Bot::Event::MessageType::Image, Line::Bot::Event::MessageType::Video
          response = client.get_message_content(event.message["id"])
          tf = Tempfile.open("content")
          tf.write(response.body)
        end
      end
    end
    head :ok
  end

  private

  # @return 一覧の文字列
  def get_list_message(boxId:)
    spots_list = get_from_jsonbox(boxId: boxId)
    convert_wants_list_to_text(spots_list)
  end

  def get_from_jsonbox(boxId:)
    url = get_box_uri(boxId: boxId)
    response = Net::HTTP.get_response(url)
    spots_list = convert_to_json(response.body)
    logger.debug "jsonboxID: #{boxId} から: #{spots_list}を取得しました。#{response.code}"
    spots_list
  end

  # @param Hash
  def post_to_jsonbox(data, boxId:)
    uri = get_box_uri(boxId: boxId)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme === "https"

    params = { spotname: data }
    headers = { "Content-Type" => "application/json" }
    response = http.post(uri.path, params.to_json, headers)
    logger.info("id:#{boxId}に#{params}をpostしました。")
  end

  def convert_wants_list_to_text(spots)
    text = "【行きたいところ一覧】"
    spots.each do |spot|
      text += "\n" + spot["spotname"]
    end
    text
  end

  def build_box_uri(boxId:)
    URI.parse(JSON_BOX_ROOT_URL + Digest::MD5.hexdigest(boxId))
  end

  def convert_to_json(str)
    JSON.parse(str)
  end
end
