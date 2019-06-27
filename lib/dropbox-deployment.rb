require 'dropbox_api'
require 'yaml'
require 'logger'
require 'find'
require 'pathname'
require 'dotenv/load'

module DropboxDeployment
  # Does the deployment to dropbox
  # noinspection RubyClassVariableUsageInspection
  class Deployer

    def initialize
      @@logger = Logger.new(STDOUT)
      @@logger.level = Logger::WARN
    end

    def upload_file(dropbox_client, file, dropbox_path)
      file_name = File.basename(file)
      @@logger.debug('Uploading ' + file_name + ' to ' + dropbox_path + '/' + file_name)
      File.open(file) do |io|
        dropbox_client.upload_by_chunks dropbox_path + '/' + file_name, io, mode: :overwrite
      end
    end

    def upload_directory(dropbox_client, directory_path, dropbox_path)
      Find.find(directory_path) do |file|

        unless File.directory?(file)
          current_file_dir = File.dirname(file)
          if current_file_dir == directory_path
            modified_path = dropbox_path
          else
            # adjust for if we are a subdirectory within the desired saved build folder
            modified_path = dropbox_path + '/' + Pathname.new(current_file_dir).relative_path_from(Pathname.new(directory_path)).to_s
          end

          upload_file(dropbox_client, file, modified_path)
        end
      end
    end

    def setup(options = {})
      config = {}

      if File.file?('dropbox-deployment.yml')
        config = YAML.load_file('dropbox-deployment.yml')
        unless config.has_key?('deploy')
          puts "\nError in config file! Build file must contain a `deploy` object.\n\n"
          exit(1)
        end

        options = config["deploy"].merge(options)
      end

      artifact_path = options.fetch('artifacts_path')
      dropbox_path = options.fetch('dropbox_path')

      if not options.key? 'env'
        options['env'] = 'DROPBOX_OAUTH_BEARER'
      end

      if ENV[ options['env'] ].nil?
        puts "\nYou must have an environment variable of `" + options['env'] + "` in order to deploy to Dropbox\n\n"
        exit(1)
      end

      if options['debug']
        @@logger.level = Logger::DEBUG
        @@logger.debug('We are in debug mode')
      end

      dropbox_client = DropboxApi::Client.new(ENV[ options['env'] ])

      if not options.key? 'max_days'
        options['max_days'] = 0
      end

      if not options.key? 'max_files'
        options['max_files'] = 0
      end

      if not dropbox_path.start_with? '/'
        dropbox_path = '/' + dropbox_path
      end

      return options, artifact_path, dropbox_path, dropbox_client
    end

    def download(options = {})
      options, artifact_path, dropbox_path, dropbox_client = setup options

      # Download a file
      @@logger.debug('Artifact Path: ' + artifact_path)
      @@logger.debug('Dropbox Path: ' + dropbox_path)

      out = File.open(artifact_path, 'wb')
      dropbox_client.download dropbox_path do |chunk|
        out.write chunk
      end
    end

    def prune(options = {})
      options, artifact_path, dropbox_path, dropbox_client = setup options

      # Files older than 1 day
      pruneDays = options['max_days']
      pruneTime = Time.now - (60 * 60 * 24 * pruneDays)
      maxFiles = options['max_files']

      files = dropbox_client.list_folder(dropbox_path, {'recursive': true}).entries
      files.delete_if { |x| not x.is_a? DropboxApi::Metadata::File }
      files.sort_by &:server_modified

      @@logger.debug('Number of files: %d' % [files.size])

      # First prune files over the max number (oldest first)
      if files.size > maxFiles and 0 < maxFiles
        files[0..(files.size - maxFiles - 1)].each do |f|
          @@logger.debug('Delete: ' + f.path_display)
          dropbox_client.delete(f.path_display)
        end

        files = files[(files.size - maxFiles)..files.size]

        files.each do |f|
          @@logger.debug('Keep: ' + f.path_display)
        end
      end

      @@logger.debug('Looking at older files')

      # Now prune any files older then requested
      if 0 < pruneDays
        files.each do |f|
          if f.server_modified < pruneTime
            @@logger.debug('Delete: ' + f.path_display)
            dropbox_client.delete(f.path_display)
          end
        end
      end
    end

    def deploy(options = {})
      options, artifact_path, dropbox_path, dropbox_client = setup options

      # Upload all files
      @@logger.debug('Artifact Path: ' + artifact_path)
      @@logger.debug('Dropbox Path: ' + dropbox_path)
      is_directory = File.directory?(artifact_path)
      @@logger.debug("Is directory: #{is_directory}")
      if is_directory
        upload_directory(dropbox_client, artifact_path, dropbox_path)
      else
        artifact_file = File.open(artifact_path)
        upload_file(dropbox_client, artifact_file, dropbox_path)
      end
      @@logger.debug('Uploading complete')
    end

    def exists(options = {})
      options, artifact_path, dropbox_path, dropbox_client = setup options

      search_path = options['search']

      @@logger.debug('Search Path: ' + search_path)
      @@logger.debug('Dropbox Path: ' + dropbox_path)

      begin
        found = false

        dropbox_client.search(search_path, dropbox_path).matches.each do |f|
          if f.resource.name == search_path
            found = true
            break
          end
        end

        if found
          @@logger.debug('File found')

          return 0
        else
          @@logger.debug('File not found')

          return -1
        end
      rescue
        @@logger.debug('File not found')

        return -1
      end
    end
  end
end
