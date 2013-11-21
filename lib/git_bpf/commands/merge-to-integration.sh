currBranch=$(git branch | sed -n '/\* /s///p')
choice=""

if [ -z "$1" ]; then
    echo "No feature branch supplied"
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
		echo.
		echo "Syncing integration branch from remote..."
		git pull origin integration
	else
		exit 1
	fi
else
	echo.
	echo "Syncing integration branch from remote..."
	git pull origin integration
fi

echo.
echo -n "Merging feature branch "
echo -e -n "\033[1;36m$1"
echo -e "\033[0m into integration branch..."

mergeResult=$(git merge --no-ff $1)
echo.
if [ "$mergeResult" = "Already up-to-date." ]; then
	echo -e "\033[1;32mFeature branch has already been merged into integration branch."
	echo "Nothing to do."
else
	echo -e "\033[1;32mMerging complete."
	echo.
	echo -e -n "\033[1;31mPlease resolve any conflicts now!"
fi
echo -e '\033[0m'
