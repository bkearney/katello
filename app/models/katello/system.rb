module Katello
  class System < Katello::Model
    self.include_root_in_json = false

    include ForemanTasks::Concerns::ActionSubject
    include Glue::Candlepin::Consumer if SETTINGS[:katello][:use_cp]
    include Glue::Pulp::Consumer if SETTINGS[:katello][:use_pulp]
    include Glue if SETTINGS[:katello][:use_cp] || SETTINGS[:katello][:use_pulp]
    include Authorization::System

    audited :on => [:create], :allow_mass_assignment => true

    belongs_to :environment, :class_name => "Katello::KTEnvironment", :inverse_of => :systems
    belongs_to :foreman_host, :class_name => "::Host::Managed", :foreign_key => :host_id, :inverse_of => :content_host

    has_many :applicable_errata, :through => :system_errata, :class_name => "Katello::Erratum", :source => :erratum
    has_many :system_errata, :class_name => "Katello::SystemErratum", :dependent => :destroy, :inverse_of => :system

    has_many :bound_repositories, :through => :system_repositories, :class_name => "Katello::Repository", :source => :repository
    has_many :system_repositories, :class_name => "Katello::SystemRepository", :dependent => :destroy, :inverse_of => :system

    has_many :task_statuses, :class_name => "Katello::TaskStatus", :as => :task_owner, :dependent => :destroy
    has_many :system_activation_keys, :class_name => "Katello::SystemActivationKey", :dependent => :destroy
    has_many :activation_keys, :through => :system_activation_keys

    has_many :system_host_collections, :class_name => "Katello::SystemHostCollection", :dependent => :destroy
    has_many :host_collections, :through      => :system_host_collections

    has_many :audits, :class_name => "::Audit", :as => :auditable, :dependent => :destroy

    belongs_to :content_view, :inverse_of => :systems

    has_one :capsule,
            :class_name => "::SmartProxy",
            :inverse_of => :content_host,
            :foreign_key => :content_host_id,
            :dependent => :nullify

    validates_lengths_from_database
    before_validation :set_default_content_view, :unless => :persisted?
    validates :environment, :presence => true
    validates :content_view, :presence => true, :allow_blank => false
    validates_with Validators::NoTrailingSpaceValidator, :attributes => :name
    validates :location, :length => {:maximum => 255}
    validates_with Validators::ContentViewEnvironmentValidator
    validates_with Validators::KatelloNameFormatValidator, :attributes => :name

    before_create :fill_defaults

    scope :in_environment, ->(env) { where('environment_id = ?', env) unless env.nil? }
    scope :by_uuids, ->(uuids) { where(:uuid => uuids) }

    scoped_search :on => :name, :complete_value => true
    scoped_search :in => :activation_keys, :on => :name, :complete_value => true, :rename => :activation_key
    scoped_search :in => :content_view, :on => :name, :complete_value => true, :rename => :content_view
    scoped_search :in => :fact_values, :on => :value, :in_key => :fact_names, :on_key => :name, :rename => :facts, :complete_value => true,
                  :only_explicit => true, :ext_method => :search_cast_facts
    scoped_search :on => :description, :complete_value => true
    scoped_search :in => :host_collections, :on => :name, :complete_value => true, :rename => :host_collection
    scoped_search :in => :environment, :on => :name, :complete_value => true, :rename => :environment

    has_many :fact_values, :through => :foreman_host
    has_many :fact_names, :through => :fact_values

    def self.in_organization(organization)
      where(:environment_id => organization.kt_environments.pluck(:id))
    end

    def self.in_organizations(organizations)
      where(:environment_id => organizations.collect { |org| org.kt_environments.pluck(:id) })
    end

    def self.in_content_view_version_environments(version_environments)
      #takes a structure of [{:content_view_version => ContentViewVersion, :environments => [KTEnvironment]}]
      queries = version_environments.map do |version_environment|
        version = version_environment[:content_view_version]
        env_ids = version_environment[:environments].map(&:id)
        "(#{table_name}.content_view_id = #{version.content_view_id} AND #{table_name}.environment_id IN (#{env_ids.join(',')}))"
      end
      where(queries.join(" OR "))
    end

    def self.uuids_to_ids(uuids)
      systems = by_uuids(uuids)
      ids_not_found = Set.new(uuids).subtract(systems.pluck(:uuid))
      fail Errors::NotFound, _("Systems [%s] not found.") % ids_not_found.to_a.join(',') unless ids_not_found.blank?
      systems.pluck(:id)
    end

    def self.with_non_installable_errata(errata)
      subquery = Katello::Erratum.select("#{Katello::Erratum.table_name}.id").installable_for_systems
                 .where("#{Katello::SystemRepository.table_name}.system_id = #{Katello::System.table_name}.id").to_sql
      self.joins(:applicable_errata).where("#{Katello::Erratum.table_name}.id" => errata).where("#{Katello::Erratum.table_name}.id NOT IN (#{subquery})").uniq
    end

    def self.with_applicable_errata(errata)
      self.joins(:applicable_errata).where("#{Katello::Erratum.table_name}.id" => errata)
    end

    def self.with_installable_errata(errata)
      non_installable = System.with_non_installable_errata(errata)
      subquery = Katello::Erratum.select("#{Katello::Erratum.table_name}.id").installable_for_systems.where("#{Katello::SystemRepository.table_name}.system_id = #{Katello::System.table_name}.id")

      query = self.joins(:applicable_errata).where("#{Katello::Erratum.table_name}.id" => errata).where("#{Katello::Erratum.table_name}.id" => subquery)
      query = query.where.not("katello_systems.id" => non_installable) unless non_installable.empty?
      query.uniq
    end

    def registered_by
      audits.first.try(:username) unless activation_keys.length > 0
    end

    class << self
      def architectures
        { 'i386' => 'x86', 'ia64' => 'Itanium', 'x86_64' => 'x86_64', 'ppc' => 'PowerPC',
          's390' => 'IBM S/390', 's390x' => 'IBM System z', 'sparc64' => 'SPARC Solaris',
          'i686' => 'i686'}
      end

      def virtualized
        { "physical" => N_("Physical"), "virtualized" => N_("Virtual") }
      end
    end

    delegate :organization, to: :environment

    def consumed_pool_ids
      self.pools.collect { |t| t['id'] }
    end

    def installable_errata(env = nil, content_view = nil)
      repos = if env && content_view
                Katello::Repository.in_environment(env).in_content_views([content_view])
              else
                self.bound_repositories.pluck(:id)
              end

      self.applicable_errata.in_repositories(repos).uniq
    end

    def available_releases
      self.content_view.version(self.environment).available_releases
    end

    def consumed_pool_ids=(attributes)
      attribs_to_unsub = consumed_pool_ids - attributes
      attribs_to_unsub.each do |id|
        self.unsubscribe id
      end

      attribs_to_sub = attributes - consumed_pool_ids
      attribs_to_sub.each do |id|
        self.subscribe id
      end
    end

    def filtered_pools(match_system, match_installed, no_overlap)
      if match_system
        pools = self.available_pools
      else
        pools = self.all_available_pools
      end

      # Only available pool's with a product on the system'
      if match_installed
        pools = pools.select do |pool|
          self.installedProducts.any? do |installed_product|
            pool['providedProducts'].any? do |provided_product|
              installed_product['productId'] == provided_product['productId']
            end
          end
        end
      end

      # None of the available pool's products overlap a consumed pool's products
      if no_overlap
        pools = pools.select do |pool|
          pool['providedProducts'].all? do |provided_product|
            self.entitlements.all? do |consumed_entitlement|
              consumed_entitlement.providedProducts.all? do |consumed_product|
                consumed_product.cp_id != provided_product['productId']
              end
            end
          end
        end
      end

      return pools
    end

    def save_bound_repos_by_path!(paths)
      repos = []
      paths.each do |path|
        possible_repos = Repository.where(:relative_path => path.gsub('/pulp/repos/', ''))
        if possible_repos.empty?
          Rails.logger.warn("System #{self.name} (#{self.id}) requested binding to unknown repo #{path}")
        else
          repos << possible_repos.first
          Rails.logger.warn("System #{self.name} (#{self.id}) requested binding to path #{path} matching \
                       #{possible_repos.size} repositories.") if possible_repos.size > 1
        end
      end

      self.bound_repositories = repos
      self.save!
    end

    def install_packages(packages)
      pulp_task = self.install_package(packages)
      save_task_status(pulp_task, :package_install, :packages, packages)
    end

    def uninstall_packages(packages)
      pulp_task = self.uninstall_package(packages)
      save_task_status(pulp_task, :package_remove, :packages, packages)
    end

    def update_packages(packages = nil)
      # if no packages are provided, a full system update will be performed (e.g ''yum update' equivalent)
      pulp_task = self.update_package(packages)
      save_task_status(pulp_task, :package_update, :packages, packages)
    end

    def install_package_groups(groups)
      pulp_task = self.install_package_group(groups)
      save_task_status(pulp_task, :package_group_install, :groups, groups)
    end

    def uninstall_package_groups(groups)
      pulp_task = self.uninstall_package_group(groups)
      save_task_status(pulp_task, :package_group_remove, :groups, groups)
    end

    def install_errata(errata_ids)
      pulp_task = self.install_consumer_errata(errata_ids)
      save_task_status(pulp_task, :errata_install, :errata_ids, errata_ids)
    end

    def as_json(options)
      json = super(options)
      json['environment'] = environment.as_json unless environment.nil?
      json['activation_key'] = activation_keys.as_json unless activation_keys.nil?

      json['content_view'] = content_view.as_json if content_view
      json['ipv4_address'] = facts.try(:[], 'network.ipv4_address') if respond_to?(:facts)

      if respond_to?(:virtual_guest)
        if self.virtual_guest == 'true'
          json['virtual_host'] = self.virtual_host.attributes if self.virtual_host
        else
          json['virtual_guests'] = self.virtual_guests.map(&:attributes)
        end
      end

      if options[:expanded]
        json['editable'] = editable?
        json['type'] = type
      end

      json
    end

    def hypervisor?
      self.is_a? Hypervisor
    end

    def system_type
      if respond_to?(:virtual_guest) && virtual_guest
        _("Virtual Guest")
      else
        case self
        when Hypervisor
          _("Hypervisor")
        else
          _("Host")
        end
      end
    end

    def refresh_tasks
      refresh_running_tasks
      import_candlepin_tasks
    end

    def tasks
      refresh_tasks
      self.task_statuses
    end

    def reportable_data(options = {})
      hash = self.as_json(options.slice(:only, :except))
      if options[:methods]
        options[:methods].each { |method| hash[method] = self.send(method) }
      end
      hash.with_indifferent_access
    end

    def self.available_locks
      [:read, :write]
    end

    def related_resources
      self.organization
    end

    def to_action_input
      super.merge(uuid => uuid)
    end

    def import_applicability(partial = true)
      consumer = self
      ::Katello::Util::Support.active_record_retry do
        ActiveRecord::Base.transaction do
          errata_uuids = pulp_errata_uuids
          if partial
            consumer_uuids = consumer.applicable_errata.pluck("#{Erratum.table_name}.uuid")
            to_remove = consumer_uuids - errata_uuids
            to_add = errata_uuids - consumer_uuids
          else
            to_add = errata_uuids
            to_remove = nil
            Katello::SystemErratum.where(:system_id => self.id).delete_all
          end
          insert_errata_applicability(to_add) unless to_add.blank?
          remove_errata_applicability(to_remove) unless to_remove.blank?
        end
      end
    end

    def available_content
      self.products.flat_map(&:available_content)
    end

    private

    def self.search_cast_facts(key, operator, value)
      {
        :conditions => "fact_names.name = '#{key.split('.')[1]}' AND #{cast_facts(key, operator, value)}",
        :include    => :fact_names
      }
    end

    def self.cast_facts(_key, operator, value)
      is_int = (value =~ /\A[-+]?\d+\z/) || (value.is_a?(Integer))
      is_pg = ActiveRecord::Base.connection.adapter_name.downcase.starts_with? 'postgresql'
      # Once Postgresql 8 support is removed (used in CentOS 6), this could be replaced to only keep the first form (working well with PG 9)
      if (is_int && !is_pg)
        casted = "CAST(fact_values.value AS DECIMAL) #{operator} #{value}"
      elsif (is_int && is_pg && operator !~ /LIKE/i)
        casted = "fact_values.value ~ E'^\\\\d+$' AND CAST(fact_values.value AS DECIMAL) #{operator} #{value}"
      else
        casted = "fact_values.value #{operator} '#{value}'"
      end
      casted
    end

    def insert_errata_applicability(uuids)
      applicable_errata_ids = ::Katello::Erratum.where(:uuid => uuids).pluck(:id)
      unless applicable_errata_ids.empty?
        inserts = applicable_errata_ids.map { |erratum_id| "(#{erratum_id.to_i}, #{id.to_i})" }
        sql = "INSERT INTO katello_system_errata (erratum_id, system_id) VALUES #{inserts.join(', ')}"
        ActiveRecord::Base.connection.execute(sql)
      end
    end

    def remove_errata_applicability(uuids)
      applicable_errata_ids = ::Katello::Erratum.where(:uuid => uuids).pluck(:id)
      Katello::SystemErratum.where(:system_id => self.id, :erratum_id => applicable_errata_ids).delete_all
    end

    def refresh_running_tasks
      ids = self.task_statuses.where(:state => [:waiting, :running]).pluck(:id)
      TaskStatus.refresh(ids)
    end

    def save_task_status(pulp_task, task_type, parameters_type, parameters)
      TaskStatus.make(self, pulp_task, task_type, parameters_type => parameters)
    end

    def fill_defaults
      self.description = _("Initial Registration Params") unless self.description
      self.location = _("None") unless self.location
    end

    def set_default_content_view
      self.content_view = self.environment.try(:default_content_view) unless self.content_view
    end

    # rubocop:disable SymbolName
    def collect_installed_product_names
      self.installedProducts ? self.installedProducts.map { |p| p[:productName] } : []
    end

    def self.humanize_class_name(_name = nil)
      _('Content Host')
    end
  end
end
