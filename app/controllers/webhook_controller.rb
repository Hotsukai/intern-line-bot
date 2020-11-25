require "line/bot"
require "net/http"
require "uri"
require "json"

class WebhookController < ApplicationController
  protect_from_forgery except: [:callback] # CSRF対策無効化

  def client
    @client ||= Line::Bot::Client.new { |config|
      config.channel_secret = ENV["LINE_CHANNEL_SECRET"]
      config.channel_token = ENV["LINE_CHANNEL_TOKEN"]
    }
  end

  # @return Array of Hash JSONboxのすべてのデータのJSON
  def get_from_jsonbox
    url = URI.parse(ENV["JSON_BOX_URL"])
    response = Net::HTTP.get_response(url)
    data = JSON.parse(response.body)
    logger.debug "jsonbox : #{data},#{response.code}"
    data
  end

  # @param Hash
  def post_to_jsonbox(data)
    uri = URI.parse(ENV["JSON_BOX_URL"])
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme === "https"

    params = data
    headers = { "Content-Type" => "application/json" }
    response = http.post(uri.path, params.to_json, headers)

    response.code # status code
    response.body # response body
  end

  def callback
    body = request.body.read

    signature = request.env["HTTP_X_LINE_SIGNATURE"]
    unless client.validate_signature(body, signature)
      head 470
    end

    events = client.parse_events_from(body)
    events.each { |event|
      logger.debug "****************\nevent source : #{event["source"]["roomId"]}"
      case event
      when Line::Bot::Event::Message
        case event.type
        when Line::Bot::Event::MessageType::Text
          case event.message["text"]
          when /\/追加 .+/u
            logger.info "追加に入りました"
          when /\/一覧/
            logger.info "一覧に入りました"
            text = ""
            get_from_jsonbox.each do |current_text|
              text += current_text["name"] + "\n"
            end
            logger.info text
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
          logger.info "メッセージを送信しました。response: #{response} : #{event["replyToken"]} : #{message[:text]}"
        when Line::Bot::Event::MessageType::Image, Line::Bot::Event::MessageType::Video
          response = client.get_message_content(event.message["id"])
          tf = Tempfile.open("content")
          tf.write(response.body)
        end
      end
    }
    head :ok
  end
end
