currBranch=$(git branch | sed -n '/\* /s///p')
choice=""

if [ -z "$1" ]; then
    echo "No feature branch supplied"
	exit 1
fi

featureBranch=$(git branch | sed -n "/$1/p")
if [ -z "$featureBranch" ]; then
	echo "Feature branch $featureBranch not found. Please ensure you have spelled the branch name correctly"
	exit 1
fi

if [ "$currBranch" != "integration" ]; then
	echo -e "\033[1;36mYou are currently on branch $currBranch."
	echo -e -n "\033[1;33mCheckout integration branch now? "
	echo -e -n '\033[0m'
	read choice
	if [ "$choice" = "y" ]; then
		echo.
		echo "Checking out integration branch..."
		git checkout integration
	else
		exit 1
	fi
fi

remote=$(git config --get gitbpf.remotename)

echo.
echo "Syncing integration branch from remote '$remote'..."
syncIntegration=$(git pull $remote integration)
echo "$syncIntegration"

echo.
echo -n "Merging feature branch "
echo -e -n "\033[1;36m$1"
echo -e "\033[0m into integration branch..."

# Run git merge with no fast-forward option
mergeResult=$(git merge --no-ff $1)
echo.
if [ "$mergeResult" = "Already up-to-date." ]; then
	echo -e "\033[1;32mFeature branch has already been merged into integration branch."
	echo.
	echo "If you are working on a shared feature branch, another developer may have already merged your commits."
else
	# Check if the merge command resulted in conflicts
	numConflicts="$(echo $mergeResult | grep "Automatic merge failed; fix conflicts and then commit the result." | wc -l | awk {'print $1'})"
	if [[ ( "$numConflicts" > 0 ) ]]; then
		echo -e "\033[1;32mMerging complete."
		echo.
		echo -e -n "\033[1;31mConflicts were detected. Please resolve any conflicts now and commit your changes."
	else
		echo -e "\033[1;32mMerging complete."
		echo.
		echo -e -n "\033[1;32mNo conflicts detected."
	fi
fi
echo -e '\033[0m'
