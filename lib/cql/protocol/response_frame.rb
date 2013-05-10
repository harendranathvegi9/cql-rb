# encoding: utf-8

require 'ipaddr'
require 'bigdecimal'
require 'set'


module Cql
  module Protocol
    class ResponseFrame
      def initialize(buffer=ByteBuffer.new)
        @headers = FrameHeaders.new(buffer)
        check_complete!
      end

      def stream_id
        @headers && @headers.stream_id
      end

      def header_length
        8
      end

      def body_length
        @headers && @headers.length
      end

      def body
        @body.response
      end

      def complete?
        @body && @body.complete?
      end

      def <<(str)
        if @body
          @body << str
        else
          @headers << str
          check_complete!
        end
      end

      private

      def check_complete!
        if @headers.complete?
          @body = create_body
        end
      end

      def create_body
        body_type = begin
          case @headers.opcode
          when 0x00 then ErrorResponse
          when 0x02 then ReadyResponse
          when 0x03 then AuthenticateResponse
          when 0x06 then SupportedResponse
          when 0x08 then ResultResponse
          when 0x0c then EventResponse
          else
            raise UnsupportedOperationError, "The operation #{@headers.opcode} is not supported"
          end
        end
        FrameBody.new(@headers.buffer, @headers.length, body_type)
      end

      class FrameHeaders
        attr_reader :buffer, :protocol_version, :stream_id, :opcode, :length

        def initialize(buffer)
          @buffer = buffer
          check_complete!
        end

        def <<(str)
          @buffer << str
          check_complete!
        end

        def complete?
          !!@protocol_version
        end

        private

        def check_complete!
          if @buffer.length >= 8
            @protocol_version = @buffer.read_byte(true)
            @flags = @buffer.read_byte(true)
            @stream_id = @buffer.read_byte(true)
            @opcode = @buffer.read_byte(true)
            @length = @buffer.read_int
            raise UnsupportedFrameTypeError, 'Request frames are not supported' if @protocol_version > 0
            @protocol_version &= 0x7f
          end
        end
      end

      class FrameBody
        attr_reader :response, :buffer

        def initialize(buffer, length, type)
          @buffer = buffer
          @length = length
          @type = type
          check_complete!
        end

        def <<(str)
          @buffer << str
          check_complete!
        end

        def complete?
          !!@response
        end

        private

        def check_complete!
          if @buffer.length >= @length
            extra_length = @buffer.length - @length
            @response = @type.decode!(@buffer)
            if @buffer.length > extra_length
              @buffer.discard(@buffer.length - extra_length)
            end
          end
        end
      end
    end

    class ResponseBody
      extend Decoding

      def self.decode!(buffer)
      end
    end

    class ErrorResponse < ResponseBody
      attr_reader :code, :message

      def initialize(*args)
        @code, @message = args
      end

      def self.decode!(buffer)
        code = read_int!(buffer)
        message = read_string!(buffer)
        case code
        when 0x1000, 0x1100, 0x1200, 0x2400, 0x2500
          DetailedErrorResponse.decode!(code, message, buffer)
        else
          new(code, message)
        end
      end

      def to_s
        %(ERROR #@code "#@message")
      end
    end

    class DetailedErrorResponse < ErrorResponse
      attr_reader :details

      def initialize(code, message, details)
        super(code, message)
        @details = details
      end

      def self.decode!(code, message, buffer)
        details = {}
        case code
        when 0x1000 # unavailable
          details[:cl] = read_consistency!(buffer)
          details[:required] = read_int!(buffer)
          details[:alive] = read_int!(buffer)
        when 0x1100 # write_timeout
          details[:cl] = read_consistency!(buffer)
          details[:received] = read_int!(buffer)
          details[:blockfor] = read_int!(buffer)
          details[:write_type] = read_string!(buffer)
        when 0x1200 # read_timeout
          details[:cl] = read_consistency!(buffer)
          details[:received] = read_int!(buffer)
          details[:blockfor] = read_int!(buffer)
          details[:data_present] = read_byte!(buffer) != 0
        when 0x2400 # already_exists
          details[:ks] = read_string!(buffer)
          details[:table] = read_string!(buffer)
        when 0x2500
          details[:id] = read_short_bytes!(buffer)
        end
        new(code, message, details)
      end

      def to_s
        %(ERROR #@code "#@message" #@details)
      end
    end

    class ReadyResponse < ResponseBody
      def self.decode!(buffer)
        new
      end

      def eql?(rs)
        self.class === rs
      end
      alias_method :==, :eql?

      def hash
        @h ||= to_s.hash ^ 0xbadc0de
      end

      def to_s
        'READY'
      end
    end

    class AuthenticateResponse < ResponseBody
      attr_reader :authentication_class

      def self.decode!(buffer)
        new(read_string!(buffer))
      end

      def initialize(authentication_class)
        @authentication_class = authentication_class
      end

      def to_s
        %(AUTHENTICATE #{authentication_class})
      end
    end

    class SupportedResponse < ResponseBody
      attr_reader :options

      def initialize(options)
        @options = options
      end

      def self.decode!(buffer)
        new(read_string_multimap!(buffer))
      end

      def to_s
        %(SUPPORTED #{options})
      end
    end

    class ResultResponse < ResponseBody
      def self.decode!(buffer)
        kind = read_int!(buffer)
        case kind
        when 0x01
          VoidResultResponse.decode!(buffer)
        when 0x02
          RowsResultResponse.decode!(buffer)
        when 0x03
          SetKeyspaceResultResponse.decode!(buffer)
        when 0x04
          PreparedResultResponse.decode!(buffer)
        when 0x05
          SchemaChangeResultResponse.decode!(buffer)
        else
          raise UnsupportedResultKindError, %(Unsupported result kind: #{kind})
        end
      end

      def void?
        false
      end
    end

    class VoidResultResponse < ResultResponse
      def self.decode!(buffer)
        new
      end

      def to_s
        %(RESULT VOID)
      end

      def void?
        true
      end
    end

    class RowsResultResponse < ResultResponse
      attr_reader :rows, :metadata

      def initialize(*args)
        @rows, @metadata = args
      end

      def self.decode!(buffer)
        column_specs = read_metadata!(buffer)
        new(read_rows!(buffer, column_specs), column_specs)
      end

      def to_s
        %(RESULT ROWS #@metadata #@rows)
      end

      private

      def self.read_column_type!(buffer)
        id, type = read_option!(buffer) do |id, b|
          case id
          when 0x01 then :ascii
          when 0x02 then :bigint
          when 0x03 then :blob
          when 0x04 then :boolean
          when 0x05 then :counter
          when 0x06 then :decimal
          when 0x07 then :double
          when 0x08 then :float
          when 0x09 then :int
          # when 0x0a then :text
          when 0x0b then :timestamp
          when 0x0c then :uuid
          when 0x0d then :varchar
          when 0x0e then :varint
          when 0x0f then :timeuuid
          when 0x10 then :inet
          when 0x20
            sub_type = read_column_type!(buffer)
            [:list, sub_type]
          when 0x21
            key_type = read_column_type!(buffer)
            value_type = read_column_type!(buffer)
            [:map, key_type, value_type]
          when 0x22
            sub_type = read_column_type!(buffer)
            [:set, sub_type]
          else
            raise UnsupportedColumnTypeError, %(Unsupported column type: #{id})
          end
        end
        type
      end

      def self.read_metadata!(buffer)
        flags = read_int!(buffer)
        columns_count = read_int!(buffer)
        if flags & 0x01 == 0x01
          global_keyspace_name = read_string!(buffer)
          global_table_name = read_string!(buffer)
        end
        column_specs = columns_count.times.map do
          if global_keyspace_name
            keyspace_name = global_keyspace_name
            table_name = global_table_name
          else
            keyspace_name = read_string!(buffer)
            table_name = read_string!(buffer)
          end
          column_name = read_string!(buffer)
          type = read_column_type!(buffer)
          [keyspace_name, table_name, column_name, type]
        end
      end

      def self.convert_type(buffer, type, size_bytes=4)
        return nil if buffer.empty?
        case type
        when :ascii
          bytes = size_bytes == 4 ? read_bytes!(buffer) : read_short_bytes!(buffer)
          bytes ? bytes.force_encoding(::Encoding::ASCII) : nil
        when :bigint
          buffer.discard(size_bytes)
          read_long!(buffer)
        when :blob
          bytes = size_bytes == 4 ? read_bytes!(buffer) : read_short_bytes!(buffer)
          bytes ? bytes : nil
        when :boolean
          buffer.discard(size_bytes)
          buffer.read(1) == Constants::TRUE_BYTE
        when :counter
          buffer.discard(size_bytes)
          read_long!(buffer)
        when :decimal
          read_decimal!(buffer, buffer.read_int)
        when :double
          buffer.discard(size_bytes)
          read_double!(buffer)
        when :float
          buffer.discard(size_bytes)
          read_float!(buffer)
        when :int
          buffer.discard(size_bytes)
          read_int!(buffer)
        when :timestamp
          buffer.discard(size_bytes)
          timestamp = read_long!(buffer)
          Time.at(timestamp/1000.0)
        when :varchar, :text
          bytes = size_bytes == 4 ? read_bytes!(buffer) : read_short_bytes!(buffer)
          bytes ? bytes.force_encoding(::Encoding::UTF_8) : nil
        when :varint
          read_varint!(buffer, buffer.read_int)
        when :timeuuid, :uuid
          buffer.discard(size_bytes)
          read_uuid!(buffer)
        when :inet
          size = size_bytes == 4 ? buffer.read_int : buffer.read_short
          IPAddr.new_ntoh(buffer.read(size))
        when Array
          buffer.discard(size_bytes)
          case type.first
          when :list
            list = []
            size = read_short!(buffer)
            size.times do
              list << convert_type(buffer, type.last, 2)
            end
            list
          when :map
            map = {}
            size = read_short!(buffer)
            size.times do
              key = convert_type(buffer, type[1], 2)
              value = convert_type(buffer, type[2], 2)
              map[key] = value
            end
            map
          when :set
            set = Set.new
            size = read_short!(buffer)
            size.times do
              set << convert_type(buffer, type.last, 2)
            end
            set
          end
        end
      end

      def self.read_rows!(buffer, column_specs)
        rows_count = read_int!(buffer)
        rows = []
        rows_count.times do |row_index|
          row = {}
          column_specs.each do |column_spec|
            row[column_spec[2]] = convert_type(buffer, column_spec[3])
          end
          rows << row
        end
        rows
      end
    end

    class SetKeyspaceResultResponse < ResultResponse
      attr_reader :keyspace

      def initialize(keyspace)
        @keyspace = keyspace
      end

      def self.decode!(buffer)
        new(read_string!(buffer))
      end

      def to_s
        %(RESULT SET_KEYSPACE "#@keyspace")
      end
    end

    class PreparedResultResponse < ResultResponse
      attr_reader :id, :metadata

      def initialize(*args)
        @id, @metadata = args
      end

      def self.decode!(buffer)
        id = read_short_bytes!(buffer)
        metadata = RowsResultResponse.read_metadata!(buffer)
        new(id, metadata)
      end

      def to_s
        %(RESULT PREPARED #{id.each_byte.map { |x| x.to_s(16) }.join('')} #@metadata)
      end
    end

    class SchemaChangeResultResponse < ResultResponse
      attr_reader :change, :keyspace, :table

      def initialize(*args)
        @change, @keyspace, @table = args
      end

      def self.decode!(buffer)
        new(read_string!(buffer), read_string!(buffer), read_string!(buffer))
      end

      def to_s
        %(RESULT SCHEMA_CHANGE #@change "#@keyspace" "#@table")
      end
    end

    class EventResponse < ResultResponse
      def self.decode!(buffer)
        type = read_string!(buffer)
        case type
        when SchemaChangeEventResponse::TYPE
          SchemaChangeEventResponse.decode!(buffer)
        when StatusChangeEventResponse::TYPE
          StatusChangeEventResponse.decode!(buffer)
        when TopologyChangeEventResponse::TYPE
          TopologyChangeEventResponse.decode!(buffer)
        else
          raise UnsupportedEventTypeError, %(Unsupported event type: "#{type}")
        end
      end
    end

    class SchemaChangeEventResponse < EventResponse
      TYPE = 'SCHEMA_CHANGE'.freeze

      attr_reader :type, :change, :keyspace, :table

      def initialize(*args)
        @change, @keyspace, @table = args
        @type = TYPE
      end

      def self.decode!(buffer)
        new(read_string!(buffer), read_string!(buffer), read_string!(buffer))
      end

      def eql?(rs)
        rs.type == self.type && rs.change == self.change && rs.keyspace == self.keyspace && rs.table == self.table
      end
      alias_method :==, :eql?

      def hash
        @h ||= begin
          h = 0
          h = ((h & 33554431) * 31) ^ @type.hash
          h = ((h & 33554431) * 31) ^ @change.hash
          h = ((h & 33554431) * 31) ^ @keyspace.hash
          h = ((h & 33554431) * 31) ^ @table.hash
          h
        end
      end

      def to_s
        %(EVENT #@type #@change "#@keyspace" "#@table")
      end
    end

    class StatusChangeEventResponse < EventResponse
      TYPE = 'STATUS_CHANGE'.freeze

      attr_reader :type, :change, :address, :port

      def initialize(*args)
        @change, @address, @port = args
        @type = TYPE
      end

      def self.decode!(buffer)
        new(read_string!(buffer), *read_inet!(buffer))
      end

      def to_s
        %(EVENT #@type #@change #@address:#@port)
      end
    end

    class TopologyChangeEventResponse < StatusChangeEventResponse
      TYPE = 'TOPOLOGY_CHANGE'.freeze

      def initialize(*args)
        super
        @type = TYPE
      end
    end
  end
end