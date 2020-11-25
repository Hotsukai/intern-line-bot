require 'line/bot'
require 'net/http'
require 'uri'
require 'json'

class WebhookController < ApplicationController
  protect_from_forgery except: [:callback] # CSRF対策無効化
  def client
    @client ||= Line::Bot::Client.new { |config|
      config.channel_secret = ENV["LINE_CHANNEL_SECRET"]
      config.channel_token = ENV["LINE_CHANNEL_TOKEN"]
    }
  end
  
  # @return JSONboxのすべてのデータのJSON
  def get_from_jsonbox
    url=URI.parse(ENV["JSON_BOX_URL"])
    response=Net::HTTP.get_response(url)
    data=JSON.parse(response.body)
    puts "jsonbox : #{data},#{response.code}"
    data
  end

  def callback
    json_box_data=get_from_jsonbox
    body = request.body.read

    signature = request.env['HTTP_X_LINE_SIGNATURE']
    unless client.validate_signature(body, signature)
      head 470
    end

    events = client.parse_events_from(body)
    events.each { |event|
      case event
      when Line::Bot::Event::Message
        case event.type
        when Line::Bot::Event::MessageType::Text
          message = {
            type: 'text',
            text: 'オウム返し！ ： '+event.message['text']+json_box_data[0]["name"]
          }
          response=  client.reply_message(event['replyToken'], message)
          puts "メッセージを送信しました。response: #{response} : #{event['replyToken']} : #{message[:text]}"
        when Line::Bot::Event::MessageType::Image, Line::Bot::Event::MessageType::Video
          response = client.get_message_content(event.message['id'])
          tf = Tempfile.open("content")
          tf.write(response.body)
        end
      end
    }
    head :ok
  end
end
