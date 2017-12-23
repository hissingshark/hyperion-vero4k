#!/bin/bash

# check we are running as root for all of the install work
if [ "$EUID" -ne 0 ]; then
	echo -e "\n***\nPlease run as sudo.\nThis is needed for installing any dependancies as we go and for the final package.\n***"
	exit
fi

# declare globals
DIALOG_OK=0
DIALOG_CANCEL=1
DIALOG_ESC=255
REPO_DIR=$(pwd)

# declare arrays
declare -a depends
declare -a flags
declare -a options
declare -a buildcmd

function depends_check() {
	if [ "$(apt list --installed $1 2>/dev/null | grep $1)" = "" ]; then
		depends+=($1)
	fi
}

function depends_install() {
	if [ ${#depends[@]} -gt 0 ]; then
		sudo apt-get install -y ${depends[@]}
		depends=()
	fi
}

function go() {
	if [ -d $1 ]; then
		cd $1
	else
		clear
		echo -e "\n***\nError!\nDirectory: $1 doesn't exist where it should!\n***\nHave you moved the install script?\nTry redownloading this repo.\n***\n"
		exit
	fi
}

function waitbox() {
	dialog --title "PLEASE WAIT..." --infobox "$1:\n\n$2" 0 0
	sleep 2
}

function install_relative() {
	# all operations wil be relative to the current working directory, so must be set correctly before calling

	# copy over bins
	go build/bin
	sudo cp * /usr/bin

	# (re)make config folder and copy over
	cd ../..
	go config
	if [ -d /etc/hyperion ]; then
		sudo rm -r /etc/hyperion
	fi
	sudo mkdir /etc/hyperion
	sudo cp * /etc/hyperion

	# (re)make effects folders and copy over
	cd ..
	go effects
	if [ -d /usr/share/hyperion ]; then
		sudo rm -r /usr/share/hyperion
	fi
	sudo mkdir -p /usr/share/hyperion/effects
	sudo cp * /usr/share/hyperion/effects

	# copy over systemd script and register
	cd $REPO_DIR
	go systemd
	sudo cp * /etc/systemd/system
	sudo systemctl daemon-reload

	cd $REPO_DIR

	# install runtime dependancies
	depends_check libqt5core5a
	depends_check	libqt5gui5
	depends_check libqt5widgets5
	depends_check libqt5network5
	depends_check libusb-1.0-0
	waitbox "Dependancies" "Installing:${depends[@]}\n"
	depends_install
}

function build_from_source() {
	cd $REPO_DIR

	if (! dialog --backtitle "Hyperion Setup on Vero4K - Build from source" --title "PROCEED?" --defaultno --no-label "Abort" --yesno "This will delete previous build files, folders and configs." 0 0); then
		return
	fi

	# check and get dependancies
	depends_check git
	depends_check cmake
	depends_check build essential
	waitbox "Dependancy Installation" ${depends[@]}
	depends_install

	# clone the srouce repo
	waitbox "Git Clone" "Downloading the Hyperion project repository"
	git clone --recursive https://github.com/hyperion-project/hyperion.git source

	go source

	# remove build dir if it exists and start anew
	if [ -d ./build ]; then
		rm -r build
	fi
	mkdir build
	go build

	# compile list of cmake bool options for building and the checklist dialog
	cmake .. &>/dev/null

	while IFS= read line; do
		tmp=($(echo $line | cut -d ':' -f 1))
		flags+=("$tmp")
		options+=("${#flags[@]}" "$tmp" "off")
	done <<< "$(cmake -L 2>/dev/null | grep BOOL)"

	# run checklist dialog
	cmd=(dialog --clear --backtitle "Hyperion Setup on Vero4K - Build from source" --title "BUILD OPTIONS" --checklist "Press SPACE to toggle options:" 15 40 7)
	exec 3>&1
	result=$("${cmd[@]}" "${options[@]}" 2>&1 1>&3)
	ret_val=$?
	exec 3>&-

	if [ "$ret_val" -eq DIALOG_OK ]; then
		# parse checklist results and prepare cmake build options
		buildcmd=(cmake)
		count=0
		for item in ${flags[@]}; do
			state=OFF

			for choice in $result; do
				if [ "$((count+1))" -eq "$choice" ]; then
					state=ON
				fi
			done

			buildcmd+=("-D$item=$state")

			((count++))
		done

	# at build time will need at the end
		buildcmd+=(-DCMAKE_BUILD_TYPE=Release -Wno-dev ..)
	else
		# CANCELLED so GO BACK to "Main Menu"
		return
	fi

	# get build dependancies
	depends_check build-essential qt5-default
	waitbox "Dependancy Installation" ${depends[@]}
	depends_install

	# compile hyperion
	waitbox "Compiling" "This will take quite a while, so I'll show you the output to keep you posted..."; sleep 2;
	${buildcmd[@]}
	make -j4

	# remove the kodi breaking qt5-default...
	waitbox "Dependancies" "Uninstalling:\nqt5-default"
	sudo apt-get remove -y qt5-default
	sudo apt-get autoremove -y

	# install everything
	cd $REPO_DIR/source
	install_relative

	dialog --title "FINISHED!"--msgbox "Start hyperion with:\nsudo systemctl start hyperion\n\nPlease check the post-installation page - you've still got a lot to do..." 0 0
}

function uninstall() {
	if (! dialog --backtitle "Hyperion Setup on Vero4K - Uninstall" --title "PROCEED?" --defaultno --no-label "Abort" --yesno "This will delete all installed binaries, effects and configs." 0 0); then
		return
	fi

	sudo rm /usr/bin/hyperion-aml
	sudo rm /usr/bin/hyperiond
	sudo rm /usr/bin/hyperion-framebuffer
	sudo rm /usr/bin/hyperion-remote
	sudo rm /usr/bin/hyperion-v4l2
	sudo rm /usr/bin/protoc

	sudo rm -r /etc/hyperion

	sudo rm -r /usr/share/hyperion

	sudo rm /etc/systemd/system/hyperion.service
	sudo systemctl daemon-reload

	# remove the dependancies...
	waitbox "Dependancies" "Uninstalling:\nlibqt5core5a libqt5gui5 libqt5widgets5 libqt5network5 libusb-1.0-0"
	sudo apt-get remove -y libqt5core5a libqt5gui5 libqt5widgets5 libqt5network5 libusb-1.0-0
	sudo apt-get autoremove -y
}

function post_installation() {
  dialog --title "Post Installation Advice" \
    --no-collapse \
    --msgbox \
"
Please refer to the hyperion wiki for configuration advice.\n \
https://hyperion-project.org/wiki/Main\n\n \
The configuration file is in /etc/hyperion\n \
Although it can be edited manually the java based gui is recommended:\n \
hypercon.jar\n\n \
It should be possible to start/stop hyperion daemon server with:\n \
sudo systemctl <start/stop> hyperion.service\n\n \
Also look out for the hyperion remote control app in the Google Play Store.
" 0 0
}


###############
# CODE BEGINS #
###############

# check for dialog and cmake
depends_check dialog
depends_check cmake

# install missing dependancies
depends_install

# start main menu
while true; do
  exec 3>&1
  selection=$(dialog \
    --backtitle "Hyperion Setup on Vero4K - Main Menu" \
    --title "Main Menu" \
    --clear \
    --cancel-label "Exit" \
    --menu "Please select:" 0 0 4 \
    "1" "Install from binary" \
    "2" "Build from source" \
    "3" "Uninstall" \
    "4" "Post Installation" \
    2>&1 1>&3)
  ret_val=$?
  exec 3>&-

  case $ret_val in
    $DIALOG_CANCEL)
      clear
      echo "Program terminated."
      exit
      ;;
    $DIALOG_ESC)
      clear
      echo "Program aborted." >&2
      exit 1
      ;;
  esac

  case $selection in
    0 )
      clear
      echo "Program terminated."
      ;;
    1 )
			if (! dialog --backtitle "Hyperion Setup on Vero4K - Install from binary" --title "PROCEED?" --defaultno --no-label "Abort" --yesno "This will delete any previous build files, folders and configs you may have." 0 0); then
				return
			fi
			cd $REPO_DIR
			install_relative
      ;;
    2 )
			build_from_source
      ;;
    3 )
			uninstall
      ;;
    4 )
			post_installation
      ;;
  esac
done