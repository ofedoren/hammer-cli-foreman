require 'hammer_cli_foreman/api'

module HammerCLIForeman

  RESOURCE_NAME_MAPPING = {
    :usergroup => :user_group,
    :usergroups => :user_groups,
    :ptable => :partition_table,
    :ptables => :partition_tables,
    :puppetclass => :puppet_class,
    :puppetclasses => :puppet_classes
  }

  def self.foreman_api
    foreman_api_connection
  end

  def self.foreman_resource!(resource_name, options={})
    if options[:singular]
      resource_name = ApipieBindings::Inflector.pluralize(resource_name.to_s).to_sym
    else
      resource_name = resource_name.to_sym
    end
    foreman_api.resource(resource_name)
  end

  def self.foreman_resource(resource_name, options={})
    begin
      foreman_resource!(resource_name, options)
    rescue NameError
      nil
    end
  end

  def self.param_to_resource(param_name)
    HammerCLIForeman.foreman_resource(param_name.gsub(/_id[s]?$/, ""), :singular => true)
  end

  def self.collection_to_common_format(data)
    if data.class <= Hash && data.has_key?('total') && data.has_key?('results')
      col = HammerCLI::Output::RecordCollection.new(data['results'],
        :total => data['total'],
        :subtotal => data['subtotal'],
        :page => data['page'],
        :per_page => data['per_page'],
        :search => data['search'],
        :sort_by => data['sort']['by'],
        :sort_order => data['sort']['order'])
    elsif data.class <= Hash
      col = HammerCLI::Output::RecordCollection.new(data)
    elsif data.class <= Array
      # remove object types. From [ { 'type' => { 'attr' => val } }, ... ]
      # produce [ { 'attr' => 'val' }, ... ]
      col = HammerCLI::Output::RecordCollection.new(data.map { |r| r.keys.length == 1 ? r[r.keys[0]] : r })
    else
      raise RuntimeError.new(_("Received data of unknown format."))
    end
    col
  end

  def self.record_to_common_format(data)
      data.class <= Hash && data.keys.length == 1 ? data[data.keys[0]] : data
  end


  class Command < HammerCLI::Apipie::Command

    def self.connection_name(resource_class)
      CONNECTION_NAME
    end

    def self.resource_config
      super.merge(HammerCLIForeman.resource_config)
    end

    def resolver
      self.class.resolver
    end

    def dependency_resolver
      self.class.dependency_resolver
    end

    def searchables
      self.class.searchables
    end

    def exception_handler_class
      #search for exception handler class in parent modules/classes
      HammerCLI.constant_path(self.class.name.to_s).reverse.each do |mod|
        return mod.exception_handler_class if mod.respond_to? :exception_handler_class
      end
      HammerCLIForeman::ExceptionHandler
    end

    def self.create_option_builder
      configurator = BuilderConfigurator.new(searchables, dependency_resolver)

      builder = ForemanOptionBuilder.new(searchables)
      builder.builders = []
      builder.builders += configurator.builders_for(resource, resource.action(action)) if resource_defined?
      builder.builders += super.builders
      builder
    end

    def self.resource_name_mapping
      HammerCLIForeman::RESOURCE_NAME_MAPPING
    end

    def self.build_options(builder_params={})
      builder_params[:resource_mapping] ||= resource_name_mapping
      builder_params = HammerCLIForeman::BuildParams.new(builder_params)
      yield(builder_params) if block_given?

      super(builder_params.to_hash, &nil)
    end

    def get_identifier(all_opts=all_options)
      @identifier ||= get_resource_id(resource, :all_options => all_opts)
      @identifier
    end

    def get_resource_id(resource, options={})
      all_opts = options[:all_options] || all_options
      if options[:scoped]
        opts = resolver.scoped_options(resource.singular_name, all_opts, :single)
      else
        opts = all_opts
      end
      begin
        resolver.send("#{resource.singular_name}_id", opts)
      rescue HammerCLIForeman::MissingSearchOptions => e
        if (options[:required] == true || resource_search_requested(resource, opts))
          logger.info "Error occured while searching for #{resource.singular_name}"
          raise e
        end
      end
    end

    def get_resource_ids(resource, options={})
      all_opts = options[:all_options] || all_options
      opts = resolver.scoped_options(resource.singular_name, all_opts, :multi)
      begin
        resolver.send("#{resource.singular_name}_ids", opts)
      rescue HammerCLIForeman::MissingSearchOptions => e
        if (options[:required] == true || resource_search_requested(resource, opts, true))
          logger.info "Error occured while searching for #{resource.name}"
          raise e
        end
      end
    end

    def self.resolver
      api = HammerCLI.context[:api_connection].get("foreman")
      HammerCLIForeman::IdResolver.new(api, HammerCLIForeman::Searchables.new)
    end

    def self.dependency_resolver
      HammerCLIForeman::DependencyResolver.new
    end

    def self.searchables
      @searchables ||= HammerCLIForeman::Searchables.new
      @searchables
    end

    def send_request
      transform_format(super)
    end

    def transform_format(data)
      HammerCLIForeman.record_to_common_format(data)
    end

    def customized_options
      # this method is deprecated and will be removed in future versions.
      # Check option_sources for custom tuning of options
      options
    end

    def request_params
      params = customized_options
      params_pruned = method_options(params)
      # Options defined manualy in commands are removed in method_options.
      # Manual ids are common so its handling is covered here
      id_option_name = HammerCLI.option_accessor_name('id')
      params_pruned['id'] = params[id_option_name] if params[id_option_name]
      params_pruned
    end

    def option_sources
      sources = super

      id_resolution = HammerCLI::Options::ProcessorList.new(name: 'IdResolution')
      id_resolution << HammerCLIForeman::OptionSources::IdParams.new(self)
      id_resolution << HammerCLIForeman::OptionSources::IdsParams.new(self)
      id_resolution << HammerCLIForeman::OptionSources::SelfParam.new(self)

      sources << id_resolution
    end

    private

    def resource_search_requested(resource, options, plural=false)
      # check if any searchable for given resource is set
      filed_options = Hash[options.select { |opt, value| !value.nil? }].keys
      searchable_options = searchables.for(resource).map do |o|
        HammerCLI.option_accessor_name(plural ? o.plural_name : o.name)
      end
      !(filed_options & searchable_options).empty?
    end
  end


  class ListCommand < Command

    action :index

    RETRIEVE_ALL_PER_PAGE = 1000
    DEFAULT_PER_PAGE = 20

    def adapter
      @context[:adapter] || :table
    end

    def send_request
      set = super
      set.map! { |r| extend_data(r) }
      set
    end

    def transform_format(data)
      HammerCLIForeman.collection_to_common_format(data)
    end

    def extend_data(record)
      record
    end

    def self.command_name(name=nil)
      super(name) || "list"
    end

    def execute
      if should_retrieve_all?
        print_data(retrieve_all)
      else
        self.option_page = (self.option_page || 1).to_i if respond_to?(:option_page)
        self.option_per_page = (self.option_per_page || HammerCLI::Settings.get(:ui, :per_page) || DEFAULT_PER_PAGE).to_i if respond_to?(:option_per_page)
        print_data(send_request)
      end

      return HammerCLI::EX_OK
    end

    def help
      return super unless resource

      meta = resource.action(action).apidoc[:metadata]
      if meta && meta[:search] && respond_to?(:option_search)
        self.class.extend_help do |h|
          h.section(_('Search fields'), id: :search_fields_section) do |h|
            h.list(search_fields_help(meta[:search]))
          end
        end
      end
      super
    end

    protected

    def retrieve_all
      self.option_per_page = RETRIEVE_ALL_PER_PAGE
      self.option_page = 1

      d = send_request
      all = d

      while (d.size == RETRIEVE_ALL_PER_PAGE) do
        self.option_page += 1
        d = send_request
        all += d
      end
      all
    end

    def pagination_supported?
      respond_to?(:option_page) && respond_to?(:option_per_page)
    end

    def should_retrieve_all?
      retrieve_all = pagination_supported? && option_per_page.nil? && option_page.nil?
      retrieve_all &&= HammerCLI::Settings.get(:ui, :per_page).nil? if output.adapter.paginate_by_default?
      retrieve_all
    end

    def search_fields_help(search_fields)
      return [] if search_fields.nil?

      search_fields.each_with_object([]) do |field, help_list|
        help_list << [
          field[:name], search_field_help_value(field)
        ]
      end
    end

    def search_field_help_value(field)
      if field[:values] && field[:values].is_a?(Array)
        _('Values') + ': ' + field[:values].join(', ')
      else
        field[:type] || field[:values]
      end
    end
  end


  class SingleResourceCommand < Command

  end


  class AssociatedResourceListCommand < ListCommand

    def parent_resource
      self.class.parent_resource
    end

    def self.parent_resource(name=nil)
      @parent_api_resource = HammerCLIForeman.foreman_resource!(name) unless name.nil?
      return @parent_api_resource if @parent_api_resource
      return superclass.parent_resource if superclass.respond_to? :parent_resource
    end

    def self.create_option_builder
      builder = super
      builder.builders << SearchablesOptionBuilder.new(parent_resource, searchables)
      builder.builders << IdOptionBuilder.new(parent_resource)
      builder
    end

    def request_params
      id_param_name = "#{parent_resource.singular_name}_id"

      params = super
      params[id_param_name] = get_resource_id(parent_resource)
      params
    end

  end


  class InfoCommand < SingleResourceCommand

    action :show

    def self.command_name(name=nil)
      super(name) || "info"
    end

    def send_request
      record = super
      extend_data(record)
    end

    def extend_data(record)
      record
    end

    def print_data(record)
      print_record(output_definition, record)
    end

  end


  class CreateCommand < Command

    action :create

    def self.command_name(name=nil)
      super(name) || "create"
    end

  end


  class UpdateCommand < SingleResourceCommand

    action :update

    def self.command_name(name=nil)
      super(name) || "update"
    end

    def self.create_option_builder
      builder = super
      builder.builders << SearchablesUpdateOptionBuilder.new(resource, searchables) if resource_defined?
      builder
    end

    def method_options_for_params(params, include_nil=true)
      opts = super
      # overwrite searchables with correct values
      searchables.for(resource).each do |s|
        new_value = get_option_value("new_#{s.name}")
        opts[s.name] = new_value unless new_value.nil?
      end
      opts
    end

  end


  class DeleteCommand < SingleResourceCommand

    action :destroy

    def self.command_name(name=nil)
      super(name) || "delete"
    end

  end


  class AssociatedCommand < Command

    action :update

    def self.create_option_builder
      configurator = BuilderConfigurator.new(searchables, dependency_resolver)

      builder = ForemanOptionBuilder.new(searchables)
      builder.builders = [
        SearchablesOptionBuilder.new(resource, searchables),
        DependentSearchablesOptionBuilder.new(associated_resource, searchables)
      ]

      resources = []
      resources += dependency_resolver.resource_dependencies(resource, :only_required => true, :recursive => true)
      resources += dependency_resolver.resource_dependencies(associated_resource, :only_required => true, :recursive => true)
      resources.each do |r|
        builder.builders << DependentSearchablesOptionBuilder.new(r, searchables)
      end
      builder.builders << IdOptionBuilder.new(resource)

      builder
    end

    def associated_resource
      self.class.associated_resource
    end

    def self.associated_resource(name=nil)
      @associated_api_resource = HammerCLIForeman.foreman_resource!(name) unless name.nil?
      return @associated_api_resource if @associated_api_resource
      return superclass.associated_resource if superclass.respond_to? :associated_resource
    end

    def self.default_message(format)
      name = associated_resource ? associated_resource.singular_name.to_s : nil
      format % { :resource_name => name.gsub(/_|-/, ' ') } unless name.nil?
    end

    def get_associated_identifier
      get_resource_id(associated_resource, :scoped => true)
    end

    def get_new_ids
      []
    end

    def get_current_ids
      item = HammerCLIForeman.record_to_common_format(resource.call(:show, {:id => get_identifier}))
      if item.has_key?(association_name(true))
        item[association_name(true)].map { |assoc| assoc['id'] }
      else
        item[association_name+'_ids'] || []
      end
    end

    def request_params
      params = super
      if params.key?(resource.singular_name)
        params[resource.singular_name] = {"#{association_name}_ids" => get_new_ids }
      else
        params["#{association_name}_ids"] = get_new_ids
      end
      params['id'] = get_identifier
      params
    end

    def association_name(plural = false)
      plural ? associated_resource.name.to_s : associated_resource.singular_name.to_s
    end

  end

  class AddAssociatedCommand < AssociatedCommand

    def self.command_name(name=nil)
      name = super(name) || (associated_resource ? "add-"+associated_resource.singular_name : nil)
      name.respond_to?(:gsub) ? name.gsub('_', '-') : name
    end

    def self.desc(desc=nil)
      description = super(desc) || ''
      description.strip.empty? ? _("Associate a resource") : description
    end

    def self.failure_message(msg = nil)
      super(msg) || default_message(_('Could not associate the %{resource_name}.'))
    end

    def self.success_message(msg = nil)
      super(msg) || default_message(_('The %{resource_name} has been associated.'))
    end

    def get_new_ids
      ids = get_current_ids.map(&:to_s)
      required_id = get_associated_identifier.to_s

      ids << required_id unless ids.include? required_id
      ids
    end

  end

  class RemoveAssociatedCommand < AssociatedCommand

    def self.command_name(name=nil)
      name = super(name) || (associated_resource ? "remove-"+associated_resource.singular_name : nil)
      name.respond_to?(:gsub) ? name.gsub('_', '-') : name
    end

    def self.desc(desc=nil)
      description = super(desc) || ''
      description.strip.empty? ? _("Disassociate a resource") : description
    end

    def get_new_ids
      ids = get_current_ids.map(&:to_s)
      required_id = get_associated_identifier.to_s

      ids = ids.delete_if { |id| id == required_id }
      ids
    end

    def self.failure_message(msg = nil)
      super(msg) || default_message(_('Could not disassociate the %{resource_name}.'))
    end

    def self.success_message(msg = nil)
      super(msg) || default_message(_('The %{resource_name} has been disassociated.'))
    end
  end

  class DownloadCommand < HammerCLIForeman::SingleResourceCommand
    action :download

    def self.command_name(name = nil)
      super(name) || "download"
    end

    def request_options
      { :response => :raw }
    end

    option "--path", "PATH", _("Path to directory where downloaded content will be saved"),
        :attribute_name => :option_path

    def execute
      response = send_request
      if option_path
        filepath = store_response(response)
        print_message(_('The response has been saved to %{path}s.'), {:path => filepath})
      else
        puts response.body
      end
      return HammerCLI::EX_OK
    end

    def default_filename
      "Downloaded-#{Time.new.strftime("%Y-%m-%d")}.txt"
    end

    private

    def store_response(response)
      if response.headers.key?(:content_disposition)
        suggested_filename = response.headers[:content_disposition].match(/filename="(.*)"/)
      end
      filename = suggested_filename ? suggested_filename[1] : default_filename
      path = option_path.dup
      path << '/' unless path.end_with? '/'
      raise _("Cannot save file: %s does not exist") % path unless File.directory?(path)
      filepath = path + filename
      File.write(filepath, response.body)
      filepath
    end
  end
end
