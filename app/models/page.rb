class Page < ActiveRecord::Base
  
  acts_as_content_page
  
  belongs_to :section
  belongs_to :template, :class_name => "PageTemplate"
  
  #This association uses the version of the instance
  #This should be used when you have a page object that may or may not be the latest version of the page
  #Because it will give you the connectors for the specific version
  has_many :version_connectors, :class_name => "Connector", :conditions => 'page_version = #{version}', :order => "position"
  
  #This joins with the pages table, so therefore is only used when working with the latest version of the page
  has_many :connectors, :include => :page, :conditions => 'pages.version = connectors.page_version', :order => "position"
  
  after_update :copy_connectors!
  before_validation :append_leading_slash_to_path
  before_destroy :delete_connectors
  
  validates_presence_of :section_id
  validate :path_unique?

  named_scope :connected_to_block, lambda { |b| {:include => :connectors, :conditions => ['connectors.content_block_id = ? and connectors.content_block_type = ? and connectors.content_block_version = ?', b.id, b.class.name, b.version]} }
    
  def self.find_by_content_block(content_block, content_block_version=nil)
    all(:include => :connectors,
      :conditions => ['connectors.content_block_id = ? and connectors.content_block_type = ? and connectors.content_block_version = ?', 
        content_block.id, content_block.class.name, (content_block_version || content_block.version)])
  end
  
  #Valid options:
  #  except = An array of connector ids not to copy
  def copy_connectors!(options={})

    #@_copy_connectors_from_version gets set in the revert_to method, otherwise is unset    
    page_version = @_copy_connectors_from_version || (version-1)
    conditions = ['page_id = ? and page_version = ?', id, page_version]

    #This is primarily for the case of removing a connector, 
    #where there is a connector we want to not carry forward
    if options[:except]
      conditions.first << ' and id not in(?)'
      conditions << options[:except]
    end

    Connector.all(:conditions => conditions, :order => "page_id, page_version, container, position").each do |c|
      attrs = c.attributes.without("id", "created_at", "updated_at")
      con = Connector.new(attrs)        

      if status == "PUBLISHED" && con.content_block.status != "PUBLISHED"
        con.content_block.updated_by_page = self
        con.content_block.publish!(updated_by)
        con.content_block_version += 1 
      end

      #If we are copying connectors from a previous version, that means we are reverting this page,
      #in which case we should create a new version of the block, and connect this page to that block
      if @_copy_connectors_from_version
        block = c.content_block
        
        #If this is connected to an older version of the block,
        #then we have to get the latest version of the block,
        #revert that to whatever version this connector is pointing to
        #and connect the page to the new version of the block
        unless block.current_version?
          block = block.class.find(block.id)
          block.updated_by_page = self
          block.revert_to(c.content_block_version, updated_by)
          # block.revert_to_without_save(c.content_block_version, updated_by)
          # block.instatiate_revision.save!
          # block.send(:update_without_callbacks)
        end
        
        con.content_block = block
        con.content_block_version = block.version
      end

      con.page_version = version
      con.save!      
    end

  end

  %w(up down to_top to_bottom).each do |d|
    define_method("move_#{d}") do |connector|
      move(connector, d)
    end
  end

  def move(connector, direction)
    transaction do
      orientation = direction[/_/] ? "#{direction.sub('_', ' the ')} of" : "#{direction} within"
      self.revision_comment = "#{connector.content_block.display_name} '#{connector.content_block.name}' was moved #{orientation} #{connector.container}"
      self.reset_status
      create_new_version!
      copy_connectors!
      Connector.first(:conditions => { :page_id => id, 
        :page_version => version, 
        :content_block_id => connector.content_block_id, 
        :content_block_type => connector.content_block_type,
        :content_block_version => connector.content_block_version,
        :container => connector.container }).send("move_#{direction}")
    end    
  end

  def add_content_block!(content_block, container)
    transaction do
      self.revision_comment = "#{content_block.display_name} '#{content_block.name}' was added to the '#{container}' container"
      if status == 'PUBLISHED' && content_block.status == 'PUBLISHED' && content_block.connected_page
        self.new_status = 'PUBLISHED'
      else
        self.reset_status
      end
      create_new_version!
      copy_connectors!
      Connector.create!(:page_id => id, 
        :page_version => version, 
        :content_block => content_block, 
        :content_block_version => content_block.version,
        :container => container)
    end
  end
  
  def destroy_connector(connector)
    transaction do
      self.revision_comment = "#{connector.content_block.display_name} '#{connector.content_block.name}' was removed from the '#{connector.container}' container"
      self.reset_status
      create_new_version!
      copy_connectors!(:except => [connector.id])
      reload
      connector.freeze
    end
  end

  #This is done to let copy_connectors! know which version to pull from
  #copy_connectors! will get called later as an after_update callback
  alias_method :original_revert_to, :revert_to
  def revert_to(version, user)
    @_copy_connectors_from_version = version
    original_revert_to(version, user)
  end
    
  def delete_connectors
    Connector.delete_all "page_id = #{id}"
  end
  
  def append_leading_slash_to_path
    if path.blank?
      self.path = "/"
    elsif path[0,1] != "/"
      self.path = "/#{path}"
    end
  end
  
  def path_unique?
    conditions = ["path = ?", path]
    unless new_record?
      conditions.first << " and id != ?"
      conditions << id
    end
    if self.class.count(:conditions => conditions) > 0
      errors.add(:path, "must be unique")
    end
  end
  
  def move_to(section, user)
    self.section = section
    self.updated_by_user = user
    save
  end
  
  def layout
    template ? template.file_name : nil
  end

  def template_name
    template ? template.name : nil
  end
  
  #Returns true if the block attached to each connector in the given container is live
  def container_live?(container)
    connectors.all(:include => :page, :conditions => {:container => container.to_s}).all?{|c| c.content_block.live?}
  end
  
  def self.find_live_by_path(path)
    page = find(:first, :conditions => {:path => path})

    if page
      if page.published?
        page
      else
        live_version = page.versions.first(:conditions => {:status => "PUBLISHED"}, :order => "version desc, id desc")
        live_version ? page.as_of_version(live_version.version) : nil
      end      
    else
      nil
    end
  end
  
end