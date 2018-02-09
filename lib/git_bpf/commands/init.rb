require 'rbconfig'
is_windows = (RbConfig::CONFIG['host_os'] =~ /mswin|mingw|mingw32|cygwin/)

require 'git_bpf/lib/gitflow'
require 'git_bpf/lib/git-helpers'
require 'git_bpf/lib/repository'
require 'find'
require 'win32/file' if is_windows

#
# init: 
#
class Init < GitFlow/'init'

  include GitHelpersMixin

  @documentation = ""

  def options(opts)
    opts.script_dir_name = 'git-bpf'
    opts.remote_name = 'origin'
    opts.rerere_branch = 'rr-cache'
    opts.remote_recreate = '"*"'

    [
      ['-d', '--directory-name NAME',
        "",
        lambda { |n| opts.script_dir_name = n }],
      ['-r', '--remote-name NAME',
        "Name of remote repo for rr-cache. Defaults to origin",
        lambda { |n| opts.remote_name = n }],
      ['-b', '--rerere-branch NAME',
        "",
        lambda { |n| opts.rerere_branch = n }],
      ['-e', '--remote-recreate NAME',
        "Pattern of branches which will be used in search for merged branches in recreated branch. Dafeaults to *",
        lambda { |n| opts.remote_recreate = n }],
    ]
  end

  # Removes all aliases to git-bpf commands.
  def removeCommandAliases(repo)
    config = repo.config(true, '--list').lines.each do |line|
      next unless line.start_with? 'alias.' and line.match /\!_git\-bpf/
      a = /alias\.([a-zA-Z0-9\-_]+)\=(.)*/.match(line)[1]
      repo.config(true, '--unset', "alias.#{a}")
    end
  end

  # Removes all symlinks to targets within source_location that are found
  # within path.
  def rmSymlinks(path, source_location)
    targets_to_check = [source_location]
    all_targets = []

    # Find all symlink targets that represent a path within source_location.
    while targets_to_check.length > 0
      git_bpf_target = targets_to_check.pop
      Find.find(path) do |p|
        if File.symlink?(p)
          unless targets_to_check.include? p
            target =  File.readlink(p)
            matched_target = git_bpf_target.is_a?(Regexp) ? target =~ git_bpf_target : target.include?(git_bpf_target)
            if matched_target
              targets_to_check.push p
            end
          end
        end
      end
      all_targets.push git_bpf_target
    end

    # Now delete any symlink whose target path includes any of the paths we
    # have identified.
    Find.find(path) do |p|
      if File.symlink? p
        target = File.readlink p
        all_targets.each do |t|
          matched_target = t.is_a?(Regexp) ? target =~ t : target.include?(t)
          if matched_target
            File.unlink p
            break
          end
        end
      end
    end
  end

  def execute(opts, argv)
    if argv.length > 1
      run 'init', '--help'
      terminate
    end

    source_path = File.expand_path("..", File.dirname(__FILE__))
    target = Repository.new(argv.length == 1 ? argv.pop : Dir.getwd)

    # Perform some cleanup in case this repo was previously initalized.
    begin
      target.config(true, '--get-regexp', 'gitbpf')
      # We only get here if the attempt to read this config section did
      # not fail, which means the section exists, so we can remove it.
      # (Without the above line, although we rescue the fail, a git fatal
      # error is still output, which is confusing).
      target.config(true, '--remove-section', 'gitbpf')
    rescue
      # There was no such section, do nothing.
    end
    removeCommandAliases target
    # Create a regex to find symlinks to old gem paths.
    pattern = /(.*)\/git_bpf-(?:\d)+\.(?:\d)+\.(?:\d)+\/(.*)/
    matches = source_path.match(pattern)
    source_path_regex = %r(#{Regexp.quote(matches[1])}\/git_bpf-(?:\d)+\.(?:\d)+\.(?:\d)+\/#{Regexp.quote(matches[2])})
    rmSymlinks(target.git_dir, source_path_regex)

    #
    # 1. Link source scripts directory.
    #
    ohai "1. Linking scripts directory to '#{source_path}'."

    scripts = File.join(target.path, '.git', opts.script_dir_name)

    if not File.exists? scripts
      #File.symlink source_path, scripts
	  `cmd /c mklink /D "#{scripts}" "#{source_path}"`
    elsif File.symlink? scripts
      opoo "Symbolic link already exists."
    else
      terminate "Cannot create symbolic link (#{scripts})."
    end


    #
    # 2. Create aliases for commands.
    #
    commands = [
      'recreate-branch',
      'share-rerere',
    ]

    ohai "2. Creating aliases for commands:", commands.shell_list

    commands.each do |name|
      command = "!_git-bpf #{name}"
      target.cmd("config", "--local", "alias.#{name}", command)
    end

    command = '!sh -c \".git/git-bpf/commands/merge-to-integration.sh $1\"'
    target.cmd("config", "--local", "alias.merge-to-integration", command)


    #
    # 3. Set up rerere sharing.
    #
    ohai "3. Setting up rerere sharing."

    target.config(true, "rerere.enabled", "true")
    target.config(true, "rerere.autoupdate", "true")

    target.config(true, "gitbpf.remotename", opts.remote_name)
    target.config(true, "gitbpf.remoterecreate", opts.remote_recreate)

    rerere_path = File.join(target.git_dir, 'rr-cache')
    target_remote_url = target.remoteUrl(opts.remote_name)

    if not File.directory? rerere_path
      rerere = Repository::clone target_remote_url, rerere_path, opts.remote_name
    elsif not File.directory? File.join(rerere_path, '.git')
      opoo "Rerere cache directory already exists; Initializing repository in existing rr-cache directory."
      rerere = Repository.init rerere_path
      rerere.cmd("remote", "add", opts.remote_name, target_remote_url)
    else
      opoo "Rerere cache directory already exists and is a repository."
      rerere = Repository.new rerere_path
    end

    rerere.fetch opts.remote_name

    if rerere.branch?('rr-cache', opts.remote_name)
      # Remote has branch 'rr-cache', make sure we are currently on it.
      if not rerere.head.include? "rr-cache"
        rerere.cmd("checkout", "rr-cache")
      end
    else
      # Create orphan branch 'rr-cache' and push to remote.
      rerere.cmd("checkout", "--orphan", "rr-cache")
      rerere.cmd("rm", "-rf", "--ignore-unmatch", "#{rerere_path}/")
      rerere.cmd("commit", "-a", "--allow-empty", "-m", "Automatically creating branch to track conflict resolutions.")
      rerere.cmd("push", opts.remote_name, "rr-cache")
    end


    #
    # 4. Symlink git-hooks.
    #
    hooks_dir = File.join(target.git_dir, "hooks")
    hooks = [
      'post-commit',
      'post-checkout',
      'pre-push'
    ]

    ohai "4. Creating symbolic links to git-hooks:", hooks.shell_list

    hooks.each do |name|
      target_hook_path = File.join(hooks_dir, name)
      source_hook_path = File.join(scripts, "hooks", "#{name}.rb")
      files = Dir.glob("#{target_hook_path}*")
      write = files.empty?

      if not write and promptYN "Existing hook '#{name}' detected, overwrite?"
        write = File.delete(files.shell_s) > 0
      end

      if write
        #File.symlink source_hook_path, target_hook_path
		`cmd /c mklink "#{target_hook_path}" "#{source_hook_path}"`
      else
        opoo "Couldn't link '#{name}' hook as it already exists."
      end
    end

    #
    # Success!
    #
    ohai "Success!"
  end
end
