# suppress warnings
old_verbose, $VERBOSE = $VERBOSE, nil
# require thrift autogenerated files
require File.join(File.dirname(__FILE__), *%w[.. thrift thrift_hive])
# restore warnings
$VERBOSE = old_verbose

module RBHive
  def connect(server, port=10_000)
    connection = RBHive::Connection.new(server, port)
    ret = nil
    begin
      connection.open
      ret = yield(connection)
    ensure
      connection.close
      ret
    end
  end
  module_function :connect
  
  class StdOutLogger
    %w(fatal error warn info debug).each do |level| 
      define_method level.to_sym do |message|
        STDOUT.puts(message)
     end
   end
  end
  
  class Connection
    attr_reader :client
    
    def initialize(server, port=10_000, logger=StdOutLogger.new)
      @socket = Thrift::Socket.new(server, port)
      @transport = Thrift::BufferedTransport.new(@socket)
      @protocol = Thrift::BinaryProtocol.new(@transport)
      @client = ThriftHive::Client.new(@protocol)
      @logger = logger
      @logger.info("Connecting to #{server} on port #{port}")
      @mutex = Mutex.new
    end
    
    def open
      @transport.open
    end
    
    def close
      @transport.close
    end
    
    def client
      @client
    end
    
    def execute(query)
      execute_safe(query)
    end
    
    def priority=(priority)
      set("mapred.job.priority", priority)
    end
    
    def queue=(queue)
      set("mapred.job.queue.name", queue)
    end
    
    def set(name,value)
      @logger.info("Setting #{name}=#{value}")
      client.execute("SET #{name}=#{value}")
    end
    
    def fetch(query)
      safe do
        execute_unsafe(query)
        rows = client.fetchAll
        the_schema = SchemaDefinition.new(client.getSchema, rows.first)
        ResultSet.new(rows, the_schema)
      end
    end
    
    def fetch_in_batch(query, batch_size=1_000)
      safe do
        execute_unsafe(query)
        until (next_batch = client.fetchN(batch_size)).empty?
          the_schema ||= SchemaDefinition.new(client.getSchema, next_batch.first)
          yield ResultSet.new(next_batch, the_schema)
        end
      end
    end
    
    def first(query)
      safe do
        execute_unsafe(query)
        row = client.fetchOne
        the_schema = SchemaDefinition.new(client.getSchema, row)
        ResultSet.new([row], the_schema).first
      end
    end
    
    def schema(example_row=[])
      safe { SchemaDefinition.new(client.getSchema, example_row) }
    end
    
    def create_table(schema)
      execute(schema.create_table_statement)
    end
    
    def drop_table(name)
      name = name.name if name.is_a?(TableSchema)
      execute("DROP TABLE `#{name}`")
    end
    
    def replace_columns(schema)
      execute(schema.replace_columns_statement)
    end
    
    def add_columns(schema)
      execute(schema.add_columns_statement)
    end
    
    def method_missing(meth, *args)
      client.send(meth, *args)
    end
    
    private
    
    def execute_safe(query)
      safe { execute_unsafe(query) }
    end
    
    def execute_unsafe(query)
      @logger.info("Executing Hive Query: #{query}")
      client.execute(query)
    end
    
    def safe
      ret = nil
      @mutex.synchronize { ret = yield }
      ret
    end
  end
end
