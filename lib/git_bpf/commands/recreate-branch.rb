require 'git_bpf/lib/gitflow'
require 'git_bpf/lib/git-helpers'

#
# recreate_branch: Recreate a branch based on the merge commits it's comprised of.
#
class RecreateBranch < GitFlow/'recreate-branch'

  include GitHelpersMixin

  @@prefix = "BRANCH-PER-FEATURE-PREFIX"

  @documentation = "Recreates the source branch in place or as a new branch by re-merging all of the merge commits."


  def options(opts)
    opts.base = 'master'
    opts.exclude = []

    [
      ['-a', '--base NAME',
        "A reference to the commit from which the source branch is based, defaults to #{opts.base}.",
        lambda { |n| opts.base = n }],
      ['-b', '--branch NAME',
        "Instead of deleting the source branch and replacng it with a new branch of the same name, leave the source branch and create a new branch called NAME.",
        lambda { |n| opts.branch = n }],
      ['-x', '--exclude NAME',
        "Specify a list of branches to be excluded.",
        lambda { |n| opts.exclude.push(n) }],
      ['-l', '--list',
        "Process source branch for merge commits and list them. Will not make any changes to any branches.",
        lambda { |n| opts.list = true }],
      ['-d', '--discard',
        "Discard the existing local source branch and checkout a new source branch from the remote if one exists. If no remote is specified with -r, gitbpf will use the configured remote, or origin if none is configured.",
        lambda { |n| opts.discard = true }],
      ['-r', '--remote NAME',
        "Specify the remote repository to work with. Only works with the -d option.",
        lambda { |n| opts.remote = n }],
      ['-v', '--verbose',
        "Show more info about skipping branches etc.",
        lambda { |n| opts.verbose = true }],

    ]
  end

  def execute(opts, argv)
    if argv.length != 1
      run('recreate-branch', '--help')
      terminate
    end

    source = argv.pop

    # If no new branch name provided, replace the source branch.
    opts.branch = source if opts.branch == nil

    if not refExists? opts.base
      terminate "Cannot find reference '#{opts.base}' to use as a base for new branch: #{opts.branch}."
    end

    if opts.discard
      unless opts.remote
        repo = Repository.new(Dir.getwd)
        remote_name = repo.config(true, "--get", "gitbpf.remotename").chomp
        opts.remote = remote_name.empty? ? 'origin' : remote_name
      end
      git('fetch', opts.remote)
      if branchExists?(source, opts.remote)
        opoo "This will delete your local '#{source}' branch if it exists and create it afresh from the #{opts.remote} remote."
        if not promptYN "Continue?"
          terminate "Aborting."
        end
        git('checkout', opts.base)
        git('branch', '-D', source) if branchExists? source
        git('checkout', source)
      end
    end

    # Perform some validation.
    if not branchExists? source
      terminate "Cannot recreate branch #{source} as it doesn't exist."
    end

    if opts.branch != source and branchExists? opts.branch
      terminate "Cannot create branch #{opts.branch} as it already exists."
    end

    #
    # 1. Compile a list of merged branches from source branch.
    #
    ohai "1. Processing branch '#{source}' for merge-commits..."

    branches = getMergedBranches(opts.base, source, opts.verbose)

    if branches.empty?
      terminate "No feature branches detected, '#{source}' matches '#{opts.base}'."
    end

    if opts.list
      terminate "Branches to be merged:\n#{branches.shell_list}"
    end

    # Remove from the list any branches that have been explicity excluded using
    # the -x option
    branches.reject! do |item|
      stripped = item.gsub /^remotes\/\w+\/([\w\-\/]+)$/, '\1'
      opts.exclude.include? stripped
    end

    # Prompt to continue.
    opoo "The following branches will be merged when the new #{opts.branch} branch is created:\n#{branches.shell_list}"
    puts
    puts "If you see something unexpected check:"
    puts "a) that your '#{source}' branch is up to date"
    puts "b) if '#{opts.base}' is a branch, make sure it is also up to date."
    opoo "If there are any non-merge commits in '#{source}', they will not be included in '#{opts.branch}'. You have been warned."
    if not promptYN "Proceed with #{source} branch recreation?"
      terminate "Aborting."
    end

    #
    # 2. Backup existing local source branch.
    #
    tmp_source = "#{@@prefix}-#{source}"
    ohai "2. Creating backup of '#{source}', '#{tmp_source}'..."

    if branchExists? tmp_source
      terminate "Cannot create branch #{tmp_source} as one already exists. To continue, #{tmp_source} must be removed."
    end

    git('branch', '-m', source, tmp_source)

    #
    # 3. Create new branch based on 'base'.
    #
    ohai "3. Creating new '#{opts.branch}' branch based on '#{opts.base}'..."

    git('checkout', '-b', opts.branch, opts.base, '--quiet')

    #
    # 4. Begin merging in feature branches.
    #
    ohai "4. Merging in feature branches..."

    branches.each do |branch|
      begin
        puts " - '#{branch}'"
        # Attempt to merge in the branch. If there is no conflict at all, we
        # just move on to the next one.
        git('merge', '--quiet', '--no-ff', '--no-edit', branch)
      rescue
        # There was a conflict. If there's no available rerere for it then it is
        # unresolved and we need to abort as there's nothing that can be done
        # automatically.
        conflicts = git('rerere', 'remaining').chomp.split("\n")

        if conflicts.length != 0
          puts "\n"
          puts "There is a merge conflict with branch #{branch} that has no rerere."
          puts "Record a resoloution by resolving the conflict."
          puts "Then run the following command to return your repository to its original state."
          puts "\n"
          puts "git checkout #{tmp_source} && git branch -D #{opts.branch} && git branch -m #{opts.branch}"
          puts "\n"
          puts "If you do not want to resolve the conflict, it is safe to just run the above command to restore your repository to the state it was in before executing this command."
          terminate
        else
          # Otherwise, we have a rerere and the changes have been staged, so we
          # just need to commit.
          git('commit', '-a', '--no-edit')
        end
      end
    end

    #
    # 5. Clean up.
    #
    ohai "5. Cleaning up temporary branches ('#{tmp_source}')."

    if source != opts.branch
      git('branch', '-m', tmp_source, source)
    else
      git('branch', '-D', tmp_source)
    end
  end

  def getMergedBranches(base, source, verbose)
    repo = Repository.new(Dir.getwd)
    remote_recreate = repo.config(true, "--get", "gitbpf.remoterecreate").chomp
    remote_recreate = remote_recreate.empty? ? '*' : remote_recreate

    branches = []

    merges = git('rev-list', '--parents', '--merges', '--first-parent', '--reverse', '--format=oneline', "#{base}...#{source}").strip.split("\n")
    all_merges = git('rev-list', '--parents', '--merges', '--reverse', '--format=oneline', "#{base}...#{source}").strip.split("\n")
    diff_merges = all_merges - merges

    unless diff_merges.empty?
      puts "\nINFO: Following merge commits will be skipped:"
      puts diff_merges.shell_list
      puts '     (Possible reason: They have been merged into other merged branches.'
      puts "      OR: Mainline branch has been merged into task branch.)"
    end

    if verbose
      puts "\nINFO: Branches found between #{base} and #{source}:\n#{merges.shell_list}"
    end

    merges.each do |commits|
      parents = commits.split("\s", 4)
      merge_hash, first_parent_hash, branch_hash, commit_name = parents

      name = git('name-rev', branch_hash,'--exclude', 'refs/tags/*', '--name-only', "--refs=#{remote_recreate}").strip
      alt_base = git('name-rev', base,'--exclude', 'refs/tags/*', '--name-only').strip
      remote_heads = /\w+\/HEAD/

      if name.include? source or name.include? alt_base or name.match remote_heads
        if verbose
          puts "INFO: <#{commit_name}> skipped because '#{name}' matches #{source} / #{alt_base} / #{remote_heads}"
          puts '      Possible problem: Mainline branch has been merged into task branch.'
          puts '      Solution: Do merge manually.'
        end
      elsif name.eql? 'undefined'
        if verbose
          puts "INFO: <#{commit_name}> skipped because '#{name}' is 'undefined'"
          puts '      Possible problem: Task branch has been forced.'
          puts '      Solution: Do merge manually.'
        end
      else
        # Make sure not to include the tilde part of a branch name (e.g. '~2')
        # as this signifies a commit that's behind the head of the branch but
        # we want to merge in the head of the branch.
        name = name.partition('~')[0]
        # This can lead to duplicate branches, because the name may have only
        # differed in the tilde portion ('mybranch~1', 'mybranch~2', etc.)
        if branches.include? name
          if verbose
            puts "INFO: <#{commit_name}> skipped because it's already in the list."
         end
        else
          branches.push name
        end
      end
    end

    puts "\n"

    return branches
  end
end
