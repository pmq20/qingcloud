require 'timeout'
module Larrow
  module Qingcloud
    # base class for Qingcloud model
    class Base
      include Logger
      attr_accessor :id, :status, :delegator

      DESTROY_STATUSES = [:deleted, :ceased,:released]

      def initialize(id,options={})
        self.id = id
        options.each_pair do |k,v|
          self.send "#{k}=",v
        end
      end

      # status always be symbol
      def status= status
        @status = status.nil? ? nil : status.to_sym
      end

      def conn
        self.class.conn
      end

      def model_name
        self.class.model_name
      end

      def show(params = {})
        self.class.describe([self.id],params).first
      end

      # block method, should be delayed at caller function
      def wait_for(status)
        loop do
          data = show
          if data['status'].to_sym == status
            info "#{model_name} status changed: #{id} - #{status}"
            self.status = status
            yield data if block_given?
            break self
          else
            debug "#{model_name} wait for status: #{id} - #{data['status']}"
          end
          sleep 2
        end
      end

      def self.conn
        Qingcloud.connection
      end

      # just for state access, such as:
      #   model.running?
      # do not affect `respond_to?`
      def method_missing(method, *args, &block)
        if method.to_s.last == '?'
          status == method.to_s[0..-2].to_sym
        else
          super
        end
      end

      # multi names( used as param_name )
      # KeyPair -> keypair -> keypairs
      def self.model_name
        name.split(/::/).last
      end
      def self.singular_name
        name.split(/::/).last.downcase
      end
      def self.plural_name
        "#{singular_name}s"
      end

      def param_by(*args)
        self.class.param_by(*args)
      end

      def self.param_by(ids, init_params={})
        ids.each_with_index.reduce(init_params) do |result, (id, index)|
          result.update :"#{plural_name}.#{index + 1}" => id
        end
      end

      # convert hash data to object when block given
      def self.describe(ids, params)
        params = param_by(ids, params)
        datas = conn.service(
          'get', "Describe#{model_name}s", params
        )["#{singular_name}_set"]
        if block_given?
          datas.map do |data|
            yield data
          end
        else
          datas
        end
      end

      # destroy method generator
      #
      # destroy can be called by end user, so it will return a future
      def self.destroy_action(action)
        define_method :destroy do
          params = self.class.param_by [id]
          future(timeout:90) do
            loop do
              begin
                result = conn.get action, params
                info "destroy #{self.class.name}: #{result}"
                break result['ret_code'] == 0
              rescue ServiceError => e
                if e.message =~ /has already been deleted/
                  break :already_deleted
                else
                  sleep 2
                end
              end
            end
          end
        end
        define_method :ensure_destroy do
          params = self.class.param_by [id]
          future(timeout:90) do
            loop do
              break true if DESTROY_STATUSES.include?(@status) 
              conn.get action, params rescue nil
              sleep 2
              @status = show['status'].to_sym
            end
          end
        end
      end
    end
  end
end
