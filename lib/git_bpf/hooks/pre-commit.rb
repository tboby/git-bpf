#!/usr/bin/env ruby

currentBranch = `git branch | sed -n '/\* /s///p'`.chomp

branches = [
  "integration",
  "QA",
]

if branches.include? currentBranch
  if File.file?('.git/MERGE_MSG')
	# We're in the middle of a merge which has conflicts,
	# so we must allow the commits after the conflict is resolved.
	exit 0
  end
  
  head = `git rev-parse --verify HEAD`.chomp
  lastMerge = `git rev-list --merges --max-count=1 HEAD`.chomp
  
  if head != lastMerge
    STDERR.puts "error: Non-merge commits not allowed on integration branch.\n Please checkout your feature branch and make the commit again."
	exit 1
  end
end
