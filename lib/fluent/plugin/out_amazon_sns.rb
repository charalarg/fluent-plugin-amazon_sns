require "aws-sdk-sns"
require "fluent/plugin/output"

module Fluent::Plugin
  class AmazonSNSOutput < Output
    Fluent::Plugin.register_output('amazon_sns', self)

    helpers :compat_parameters, :inject

    DEFAULT_BUFFER_TYPE = "memory"

    config_set_default :include_tag_key, false
    config_set_default :include_time_key, true

    config_param :aws_access_key_id, :string, default: nil
    config_param :aws_secret_access_key, :string, default: nil, secret: true
    config_param :aws_region, :string, default: ENV['AWS_REGION'] || ENV['AWS_DEFAULT_REGION'] || 'us-east-1'
    config_param :aws_proxy_uri, :string, default: ENV['HTTP_PROXY']

    config_param :subject_key, :string, default: nil
    config_param :subject, :string, default: nil

    config_param :topic_name, :string, default: nil
    config_param :topic_map_tag, :bool, default: false
    config_param :remove_tag_prefix, :string, default: nil
    config_param :topic_map_key, :string, default: nil

    config_section :buffer do
      config_set_default :@type, DEFAULT_BUFFER_TYPE
    end

    def configure(conf)
      compat_parameters_convert(conf, :buffer, :inject)
      super

      @topic_generator = case
                         when @topic_name
                           ->(tag, record){ @topic_name }
                         when @topic_map_key
                           ->(tag, record){ record[@topic_map_key] }
                         when @topic_map_tag
                           ->(tag, record){ tag.gsub(/^#{@remove_tag_prefix}(\.)?/, '') }
                         else
                           raise Fluent::ConfigError, "no one way specified to decide target"
                         end
    end

    def start
      super

      options = {}
      [:access_key_id, :secret_access_key, :region].each do |key|
        options[key] = instance_variable_get "@aws_#{key}"
      end
      options[:http_proxy] = @aws_proxy_uri

      @sns_client = Aws::SNS::Client.new(options)
      @sns = Aws::SNS::Resource.new(client: @sns_client)
      @topics = get_topics
    end

    def shutdown
      super
    end

    def format(tag, time, record)
      record = inject_values_to_record(tag, time, record)
      [tag, time, record].to_msgpack
    end

    def formatted_to_msgpack_binary?
      true
    end

    def multi_workers_ready?
      true
    end

    def write(chunk)
      messages_to_send = []

      chunk.msgpack_each do |tag, time, record|
        record["time"] = Time.at(time).localtime
        subject = record.delete(@subject_key) || @subject  || 'Fluent-Notification'
        @topic = @topic_generator.call(tag, record)
        @topic = @topic.gsub(/\./, '-') if @topic # SNS doesn't allow .

        if @topics[@topic]
          messages_to_send << { message: record.to_json }

          if messages_to_send.length >= 10
            send_messages_in_batches(messages_to_send)
            messages_to_send = []
          end
        else
          $log.error "Could not find topic on SNS"
        end
      end

      send_messages_in_batches(messages_to_send) unless messages_to_send.empty?
    end

    def send_messages_in_batches(messages)
      messages.each_slice(10) do |batch|
        entries = batch.map.with_index do |msg, idx|
          {
            id: "#{idx + 1}",
            message: msg[:message]
          }
        end

        begin
          @sns_client.publish_batch(
            topic_arn: @topics[@topic].arn,
            publish_batch_request_entries: entries
          )
        rescue StandardError => e
          $log.error "Error while sending batch to SNS: #{e.message}"
        end
      end
    end

    def get_topics
      @sns.topics.inject({}) do |product, topic|
        product[topic.arn.split(/:/).last] = topic
        product
      end
    end
  end
end
