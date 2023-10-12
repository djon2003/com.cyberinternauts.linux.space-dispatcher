#!/bin/sh

########################
### Pre
########################

logLevel="NORMAL"
logOutput="BOTH"

## Load libraries
scriptDir=$(dirname "$BASH_SOURCE")
source "$scriptDir/com.cyberinternauts.linux.libraries/baselib.sh"

## Switch to script directory
switchToScriptDirectory

## Ensure launched only once
launchOnlyOnce

## Activate logs
activateLogs "$logOutput"


########################
### Configuration
########################

function loadConfiguration()
{
	local configFile="$(dirname "$0")/$(basename "$0").conf"

	# Reset configuration
	read -r -d '' resetConfigContent <<- EOM
		FILE_NEEDED_TO_PROCEED=
		MARKING_FILE_NAME="dispatched.txt"
		
		FROM_PATH=
		COMBINED_PATH=
		FROM_THRESHOLD_SPACE=20971520 # In MegaByte
		MIN_FOLDER_SIZE_TO_DISPATCH=51200  # In MegaByte
		
		TO_PATH=
		TO_THRESHOLD_SPACE=20971520 # In MegaByte

		DELETE_TEMP_PATH=
		
		SSH_HOST=
		SSH_USER=
		SSH_TO_PATH=
		SSH_COMBINED_PATH=
	EOM
	
	if [ ! -f "$configFile" ]; then
		#Create default configuration
		printf "$resetConfigContent" > $configFile
	fi
	
	#Using "eval" instead of "source" to ensure config file is using Linux ending line style
	eval "$resetConfigContent" # Reset all configuration values
	eval "$(tr -d '\015' < "$configFile")" # Load desired configuration
}

loadConfiguration

shallContinue=Y

# Paths validation
if [ "$FROM_PATH" = "" ]; then
	addLog "E" "Configuration \"FROM_PATH\" cannot be empty"
	shallContinue=N
elif [ ! -d "$FROM_PATH" ]; then
	addLog "E" "Configuration \"FROM_PATH\" \"$FROM_PATH\" does not exist"
	shallContinue=N
fi

if [ "$COMBINED_PATH" = "" ]; then
	addLog "E" "Configuration \"COMBINED_PATH\" cannot be empty"
	shallContinue=N
elif [ ! -d "$COMBINED_PATH" ]; then
	addLog "E" "Configuration \"COMBINED_PATH\" \"$COMBINED_PATH\" does not exist"
	shallContinue=N
fi

if [ "$TO_PATH" = "" ]; then
	addLog "E" "Configuration \"TO_PATH\" cannot be empty"
	shallContinue=N
elif [ ! -d "$TO_PATH" ]; then
	addLog "E" "Configuration \"TO_PATH\" \"$TO_PATH\" does not exist"
	shallContinue=N
fi

if [ "$DELETE_TEMP_PATH" = "" ]; then
	addLog "E" "Configuration \"DELETE_TEMP_PATH\" cannot be empty"
	shallContinue=N
elif [ ! -d "$DELETE_TEMP_PATH" ]; then
	addLog "E" "Configuration \"DELETE_TEMP_PATH\" \"$DELETE_TEMP_PATH\" does not exist"
	shallContinue=N
fi

# Numbers validation
isInteger='^[0-9]+$'
if ! [[ "$FROM_THRESHOLD_SPACE" =~ $isInteger ]]; then
	addLog "E" "Configuration \"FROM_THRESHOLD_SPACE\" \"$FROM_THRESHOLD_SPACE\" is not a valid number"
	shallContinue=N
fi

if ! [[ "$MIN_FOLDER_SIZE_TO_DISPATCH" =~ $isInteger ]]; then
	addLog "E" "Configuration \"MIN_FOLDER_SIZE_TO_DISPATCH\" \"$MIN_FOLDER_SIZE_TO_DISPATCH\" is not a valid number"
	shallContinue=N
fi

if ! [[ "$TO_THRESHOLD_SPACE" =~ $isInteger ]]; then
	addLog "E" "Configuration \"TO_THRESHOLD_SPACE\" \"$TO_THRESHOLD_SPACE\" is not a valid number"
	shallContinue=N
fi

[ "$shallContinue" != "Y" ] && exit # QUIT if validation failed


########################
### Main script
########################

fromPathLength=$(echo "$FROM_PATH" | wc -c)
tmpFolderTemplate="\$$(basename "$0")\$---"


## Delete not completed folder deletion
rm -rf "$DELETE_TEMP_PATH"* 2>/dev/null

## Delete not completed copy
rm -rf "$TO_PATH$tmpFolderTemplate"* 2>/dev/null


## Validate if script should run
fromFreeSpace=$(getDiskFreeSpace "$FROM_PATH" "m")
toFreeSpace=$(getDiskFreeSpace "$TO_PATH" "m")

if [ "$fromFreeSpace" = "" ]; then
	addLog "E" "FROM_PATH, \"$FROM_PATH\", doesn't exist"
	exit
fi

if [ "$toFreeSpace" = "" ]; then
	addLog "E" "TO_PATH, \"$TO_PATH\", doesn't exist"
	exit
fi

if [ $toFreeSpace -le $TO_THRESHOLD_SPACE ]; then
	addLog "N" "TO_PATH, \"$TO_PATH\", has less than $TO_THRESHOLD_SPACE MB of freespace... quitting"
	exit
fi

if [ $fromFreeSpace -ge $FROM_THRESHOLD_SPACE ]; then
	addLog "N" "FROM_PATH, \"$FROM_PATH\", has over than $FROM_THRESHOLD_SPACE MB of freespace... quitting"
	exit
fi

## Reading folders size
printf "Reading folders sizes..."
fromFolders=$(du -m --max-depth=1 "$FROM_PATH")
printf "Done\n"

shopt -s dotglob

## Sort to start by the biggest subfolder
fromFolders=$(echo "$fromFolders" | sort -nr);

## Transpose to an array to ensure changes in IFS doesn't impact the loop
IFS=$'\n' read -rd '' -a folders <<< "$fromFolders"

## Loop through subfolders: copy/compare/move/delete/mount
for index in ${!folders[@]}; do
	folderInfo="${folders[$index]}"
	addLog "D" "Begin of loop block: $folderInfo"
	folderSize=$(echo "$folderInfo" | awk '{print $1}')	
	if [ $folderSize -lt $MIN_FOLDER_SIZE_TO_DISPATCH ]; then continue; fi # Skip too small folders
	
	folderSizeLength=$(echo "$folderSize" | wc -c)
	fromFolderPath=${folderInfo:$folderSizeLength}
	folderName=$(echo "$fromFolderPath" | cut -c$fromPathLength-)
	folderName=${folderName/#\//} # Remove starting slash if any
	
	addLog "D" "folderName=||$folderName||"
	addLog "D" "fromFolderPath=||$fromFolderPath||"
	
	if [ "$folderName" = "" ]; then continue; fi # This can happen if the containing folder appears in the list
	
	fileNeededToProceed="$fromFolderPath/$FILE_NEEDED_TO_PROCEED"
	toFolderPath="$TO_PATH$folderName"
	combinedFolderPath="$COMBINED_PATH$folderName"
	afterCopyingToFreeSpace=$((toFreeSpace-folderSize))
	afterCopyingFromFreeSpace=$((fromFreeSpace+folderSize))	
	mountFolderPath=$(readlink -f "$combinedFolderPath")
	isMounted=$(mount | grep "$mountFolderPath")
	isFolderEmpty=$(ls -A "$fromFolderPath")
	
	addLog "D" "combinedFolderPath=||$combinedFolderPath||"
	addLog "D" "mountFolderPath=||$mountFolderPath||"
	addLog "D" "isMounted=||$isMounted||"
	addLog "D" "isFolderEmpty=||$isFolderEmpty||"
	addLog "D" "fileNeededToProceed=||$fileNeededToProceed||"
	addLog "D" "afterCopyingToFreeSpace=||$afterCopyingToFreeSpace||"
		
	if [ "$isMounted" != "" ]; then continue; fi # Skip mounted folder.
	if [ "$isFolderEmpty" = "" ]; then continue; fi # Skip empty folder. Either not mounted yet or not worth to move
	if [ "$FILE_NEEDED_TO_PROCEED" != "" ] && [ ! -f "$fileNeededToProceed" ]; then continue; fi # Skip folder not containing specific file
	if [ $afterCopyingToFreeSpace -le $TO_THRESHOLD_SPACE ]; then continue; fi # Skip folder too big to copy
	
	toTmpFolderPath="$(mktemp -dt -p "$TO_PATH" "$tmpFolderTemplate$folderName.XXXXXX")"
		
	addLog "D" "toFreeSpace>>afterCopyingToFreeSpace=||$toFreeSpace>>$afterCopyingToFreeSpace||"
	addLog "D" "folderInfo=||$folderInfo||"
	addLog "D" "folderSizeLength=||$folderSizeLength||"	
	addLog "D" "folderSize=||$folderSize||"
	
	# Copy folder
	printf "Copying \"$folderName\"..."
	cp -aT "$fromFolderPath" "$toTmpFolderPath"
	printf "Done\n"
	
	# Wait and compare folder
	sleep 5 # This is to give time to ensure writing is fully done (NOT using "sync" because it's not necessarily related to the previous copy)

	printf "Comparing \"$folderName\"..."
	rsync -a "$fromFolderPath/" "$toTmpFolderPath/"
	if [ $? ]; then diffOK=""; else diffOK="N"; fi
	printf "Done\n"
	
	# Finalize if copies are identical
	if [ "$diffOK" = "" ]; then
		printf "Swapping \"$folderName\"..."
			
		# Rename from tmp name to real one
		mv "$toTmpFolderPath" "$toFolderPath"
		
		# Mark folder has moved
		if [ "$MARKING_FILE_NAME" != "" ]; then
			touch "$toFolderPath/$MARKING_FILE_NAME"
		fi
		
		# Move folder to a temporary path for deletion (for faster switching)
		mv "$fromFolderPath" "$DELETE_TEMP_PATH" # Using WSeries path because the other one is a mounted point and is really slow to move
		
		# Create new empty directory as a mount point place holder
		mkdir "$fromFolderPath"
		
		# Bind this device moved folder to the new empty one
		mount --bind "$toFolderPath" "$combinedFolderPath"
		
		# Call other device to create a binding there too
		if [ "$SSH_USER" != "" ] && [ "$SSH_HOST" != "" ] && [ "$SSH_TO_PATH" != "" ] && [ "$SSH_COMBINED_PATH" != "" ]; then
			ssh -o BatchMode=yes $SSH_USER@$SSH_HOST "mount --bind \"$SSH_TO_PATH$folderName\" \"$SSH_COMBINED_PATH$folderName\""
		fi
		
		# Delete the folder in background
		rm -rf "$DELETE_TEMP_PATH$folderName" &
		printf "Done\n"
	else
		rm -rf "$toTmpFolderPath/" # Remove partially copied folder
	fi
	
	
	toFreeSpace=$afterCopyingToFreeSpace
	fromFreeSpace=$afterCopyingFromFreeSpace
	
	if [ $fromFreeSpace -ge $FROM_THRESHOLD_SPACE ]; then
		echo "Ending dispatch because there is enough free space"
		exit
	fi
		
	addLog "D" "End of loop block: $folderInfo"
	
done

addLog "D" "End of script"
