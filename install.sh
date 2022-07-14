#!/bin/bash

# check we are running as root for all of the install work
if [ "$EUID" -ne 0 ]; then
    echo -e "\n***\nPlease run as sudo.\nThis is needed for installing any dependancies as we go and for the final package.\n***"
    exit
fi

# stop any running instance of hyperion
sudo systemctl stop hyperion



#############
# CONSTANTS #
#############

DIALOG_OK=0
DIALOG_CANCEL=1
DIALOG_ESC=255

REPO_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
CUSTOM_COMMIT=$1
STABLE_COMMIT='5dc696b' # v2.0.13
SYSTEMD_UNIT='hyperion.systemd'
REPO_URL='https://github.com/hyperion-project/hyperion.ng.git'

declare -a PREBUILD_DEPENDS=(git cmake build-essential python3.7 libpython3.7-dev)
declare -a BUILD_DEPENDS=(vero3-userland-dev-osmc qtbase5-dev libqt5serialport5-dev libusb-1.0-0-dev libxrender-dev libavahi-core-dev libavahi-compat-libdnssd-dev libmbedtls-dev libpcre3-dev zlib1g-dev libjpeg-dev libqt5sql5-sqlite libssl-dev)
declare -a RUN_DEPENDS=(libqt5concurrent5 libqt5core5a libqt5dbus5 libqt5gui5 libqt5network5 libqt5printsupport5 libqt5serialport5 libqt5sql5 libqt5test5 libqt5widgets5 libqt5xml5 libusb-1.0-0 python3.7 libpython3.7 qt5-qmake libqt5sql5-sqlite libpcre16-3)
declare -a FATAL_DEPENDS=(libegl1-mesa)
declare -a LINK_LIST=(/usr/bin/flatc /usr/bin/flathash /usr/bin/gpio2spi /usr/bin/hyperion-aml /usr/bin/hyperion-framebuffer /usr/bin/hyperion-remote /usr/bin/hyperion-v4l2 /usr/bin/hyperiond /usr/bin/protoc)



#############
# VARIABLES #
#############

msg_list=()

declare -a missing_depends
declare -a flags
declare -a options
declare -a buildcmd



####################
# HELPER FUNCTIONS #
####################

# takes a list of packages and sets $missing_depends to those uninstalled
function depends_check() {
    missing_depends=()
    for package in $@; do
        if [ "$(apt list --installed $package 2>/dev/null | grep $package)" = "" ]; then
            missing_depends+=($package)
        fi
    done
}


# takes a list of packages and installs those supplied by depends_check in $missing_depends
function depends_install() {
    depends_check $@

    msg_list='Installing:\n'
    for package in "${missing_depends[@]}"; do
        msg_list=("$msg_list  $package\n")
    done

    if [ ${#missing_depends[@]} -gt 0 ]; then
        waitbox "Package Management" "$msg_list\n"
        sudo apt-get install -y ${missing_depends[@]}
        missing_depends=()
    fi
}


# changes working directory whilst checking for a legitimate path
function go() {
    if [ -d $1 ]; then
        cd $1
    else
        clear
        echo -e "\n***\nError!\nDirectory: $1 doesn't exist where it should!\n***\nHave you moved the install script?\nTry redownloading this repo.\n***\n"
        exit
    fi
}


# takes a heading and body text string for a momentary notification
function waitbox() {
    dialog --title "PLEASE WAIT..." --infobox "$1:\n\n$2" 0 0
    sleep 2
}



##################
# MAIN FUNCTIONS #
##################


function install_from_binary() {
    dialog --backtitle "Hyperion.ng Setup on Vero4K - Install from binary" --title "Advice" --msgbox \
"This will install a prebuilt version of Hyperion.ng with the most common Vero4K compatible compilation options enabled.\n
\n
It will be an older version, but also a working one.\n
\n
Please only consider building from source if you need a specific version for a bug fix or feature." 0 0

    if (dialog --backtitle "Hyperion.ng Setup on Vero4K - Install from binary" --title "PROCEED?" --defaultno --no-label "Abort" --yesno \
	  "This will delete any previous build files and folders you may have.\n
\n
It will not remove any old configs.  This will save you time if everything is working as it should.\n
\n
However, if you experience problems with your cutting edge build it might be worth running an uninstall first to delete them - in case the developers have changed something about how they work..." 0 0); then
        cd $REPO_DIR/prebuilt
        install_relative
    fi
}


function install_relative() {
    # most operations will be relative to the current working directory, so must be set correctly before calling

    # copy over bins
    waitbox "PROGRESS" "Installing binaries"
    go build/bin
    if [ -d /usr/share/hyperion ]; then
        sudo rm -r /usr/share/hyperion
    fi
    sudo mkdir -p /usr/share/hyperion/bin
    cp -r tests /usr/share/hyperion
    # in keeping with hyperion's own installer, symlinks to bins, and the service has a "working directory" of /usr/share/hyperion/bin
    sudo cp * /usr/share/hyperion/bin
    # delete existing bin syslinks first in case there are fewer to be added
    sudo rm  ${LINK_LIST[@]}
    ln -sf /usr/share/hyperion/bin/* /usr/bin/
    # copy over Lancelot script for changing double_write_mode (fixes 4K issues)
    cp $REPO_DIR/assets/drmctl.sh /usr/share/hyperion/bin

    # (re)make effects folders and copy over
    waitbox "PROGRESS" "Installing effects"
    go ../../effects
    sudo mkdir /usr/share/hyperion/effects
    sudo cp * /usr/share/hyperion/effects

    # copy over systemd script and register
    waitbox "PROGRESS" "Registering hyperion service"
    go ../bin/service
    sudo cp $SYSTEMD_UNIT /etc/systemd/system/hyperion.service
    # fix the unit file - uses %i as user name, which isn't supported in systemd (?OSMC on an out of date version)
    sudo sed -i 's/%i/osmc/g' /etc/systemd/system/hyperion.service
    # also add the pre/post-run call to drmctl.sh
    sudo sed -i '/ExecStart=/i ExecStartPre=/bin/sh -c "exec sh /usr/share/hyperion/bin/drmctl.sh start"' /etc/systemd/system/hyperion.service
    sudo sed -i '/ExecStart=/a ExecStopPost=/bin/sh -c "exec sh /usr/share/hyperion/bin/drmctl.sh stop"' /etc/systemd/system/hyperion.service
    sudo systemctl daemon-reload

    # return to base
    cd $REPO_DIR

    # install runtime dependancies
    waitbox "PROGRESS" "Checking for missing runtime dependancies"
    depends_install ${RUN_DEPENDS[@]}

    dialog --backtitle "Hyperion.ng Setup on Vero4K - Installation" --title "PROGRESS" --msgbox "INSTALLATION COMPLETED!\n\nStart hyperion with:\nsudo systemctl start hyperion\n\nPlease check the post-installation page - you've still got a lot to do..." 0 0
}


function build_from_source() {
    dialog --backtitle "Hyperion.ng Setup on Vero4K - Build from source" --title "Advice" --msgbox \
"This software is intended for the Vero4K running OSMC, therefore options relating to:\n
\n
  1. The Raspberry Pi (dispmanx),\n
  2. An X environment,\n
  3. An Apple/OSX setup\n
\n
are unsupported - likely failing to build.\n
\n
You are recommended at this time to:\n
   ENABLE AMLOGIC\n
   ENABLE FB\n
   ENABLE V4L2\n

   ENABLE FLATBUF_SERVER
   ENABLE PROTOBUF_SERVER
   ENABLE FORWARDER
   ENABLE BOBLIGHT_SERVER

   ENABLE DEV_NETWORK
   ENABLE DEV_SERIAL
   ENABLE DEV_USB_HID

   ENABLE EFFECTENGINE
   ENABLE REMOTE_CTL
\n
   DISABLE Tests\n
   and everything else to be honest.\n
\n
Feel free to use this script as a starting point for your own installer on another platform.  This is open-source afterall." 0 0

    if (! dialog --backtitle "Hyperion.ng Setup on Vero4K - Build from source" --title "PROCEED?" --defaultno --no-label "Abort" --yesno \
	  "This will delete any previous build files and folders you may have.\n
\n
It will not remove any old configs.  This will save you time if everything is working as it should.\n
\n
However, if you experience problems with your cutting edge build it might be worth running an uninstall first to delete them - in case the developers have changed something about how they work..." 0 0); then
        return
    fi

    # configure build environment - particularly it avoids floating point runtime error - now building for armv7 instead
    export CFLAGS="-I/opt/vero3/include -L/opt/vero3/lib -O3 -mcpu=cortex-a7 -mfpu=neon-vfpv4 -mfloat-abi=hard -ftree-vectorize -funsafe-math-optimizations"
    export CPPFLAGS=$CFLAGS
    export CXXFLAGS=$CFLAGS

    # check and get prebuild dependancies
    waitbox "PROGRESS" "Checking for missing pre-build dependancies"
    depends_install ${PREBUILD_DEPENDS[@]}

    cd $REPO_DIR

    # clone the source repo
    waitbox "Git Clone" "Downloading the Hyperion.ng project repository"
    if [ -d ./source ]; then
        rm -r source
    fi

    if [[ "$CUSTOM_COMMIT" == "hue" ]]; then # emergency measures for Philips Hue users - not perfect but limping along for now
        waitbox "Git Clone" "Using the 2019 beta api-entertainment fork for Philips Hue users"
        git clone --recursive --single-branch --branch entertainment-api-2019 https://github.com/SJunkies/hyperion.ng.git source
        CUSTOM_COMMIT='d6a5084' # last known good commit for Hue - development too unstable to just take the latest
    else
        git clone --recursive $REPO_URL source
    fi
    go source
    git fetch

    # checkout older commit if supplied on the command line else we'll build from last known good commit
    if [[ -n $CUSTOM_COMMIT ]]; then
        waitbox "Git Checking Out:" "Commit #$CUSTOM_COMMIT"
        git checkout $CUSTOM_COMMIT
    else
        waitbox "Git Checking Out:" "Commit #$STABLE_COMMIT"
        git checkout $STABLE_COMMIT
    fi

    # remove build dir if it exists and start anew
    if [ -d ./build ]; then
        rm -r build
    fi
    mkdir build
    go build

    # compile list of cmake bool options for building and the checklist dialog
    waitbox "PROGRESS" "Preparing build options checklist"
    sudo cmake .. &>/dev/null
    flags=()
    options=()

    while IFS= read line; do
        tmp=($(echo $line | cut -d ':' -f 1))
        flags+=("$tmp")
        options+=("${#flags[@]}" "$tmp" "off")
    done <<< "$(sudo cmake -L 2>/dev/null | grep "^ENABLE" | grep "BOOL")"

    # run checklist dialog
    cmd=(dialog --clear --backtitle "Hyperion.ng Setup on Vero4K - Build from source" --title "BUILD OPTIONS" --checklist "Press SPACE to toggle options:" 15 40 7)
    exec 3>&1
    result=$("${cmd[@]}" "${options[@]}" 2>&1 1>&3)
    ret_val=$?
    exec 3>&-

    if [ $ret_val -eq $DIALOG_OK ]; then
        # parse checklist results and prepare cmake build options
        buildcmd=(cmake -DPLATFORM=amlogic )
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

    # check and get build dependancies
    waitbox "PROGRESS" "Checking for missing build dependancies"
    depends_install ${BUILD_DEPENDS[@]}

    # compile hyperion
    waitbox "Compiling Hyperion.ng" "This will take quite a while, so I'll show you the output to keep you posted..."; sleep 2;
    sudo rm -rf *
    ${buildcmd[@]}
    make -j4
    waitbox "PROGRESS" "Build complete!"

    # organise the test programs if there are any and make everything executable
    go bin
    chmod +x *
    mkdir tests
    mv *test* tests

    # Let's save SD card wear and only remove the system breakers. Will make rebuilds quicker too.
    waitbox "Harmful Dependancies" "Uninstalling:\n${FATAL_DEPENDS[@]}"
    sudo apt-get remove -y ${FATAL_DEPENDS[@]}
    sudo apt-get autoremove -y

    # install everything
    cd ../..
    install_relative
}


function uninstall() {
    # chance to back out
    if (! dialog --backtitle "Hyperion.ng Setup on Vero4K - Uninstall" --title "PROCEED?" --defaultno --no-label "Abort" --yesno "This will delete all installed binaries and effects." 0 0); then
        return
    fi

    # delete bin sysmlinks
    sudo rm  ${LINK_LIST[@]}
    waitbox "PROGRESS" "Binaries deleted"

    # delete bins, effects and test programs
    sudo rm -r /usr/share/hyperion
    waitbox "PROGRESS" "Effects and test programs deleted"

    # delete and unregister service
    sudo rm /etc/systemd/system/hyperion.service
    sudo systemctl daemon-reload
    waitbox "PROGRESS" "Hyperion service unregistered"

    # retain configs?
    if (dialog --backtitle "Hyperion.ng Setup on Vero4K - Uninstall" --title "CONFIGURATION FILES!" --defaultno --yes-label "Delete" --no-label "Keep" --yesno "Would you like to DELETE the config files as well?" 0 0); then
        # delete configs
        sudo rm -r /home/osmc/.hyperion
        waitbox "PROGRESS" "Configuration files deleted"
    fi
    dialog --backtitle "Hyperion.ng Setup on Vero4K - Uninstall" --title "PROGRESS" --msgbox "FINISHED!\n\nHyperion.ng has been uninstalled" 0 0
}


function post_installation() {
  dialog --title "Hyperion.ng: Post Installation Advice" \
    --no-collapse \
    --msgbox "Please refer to the Hyperion wiki for configuration advice.\n
https://hyperion-project.org/wiki/Main\n
\n
There is also some experience on the OSMC forum, specifically the \"OSMC and Hyperion\" thread in the Vero4k section.\n
\n
The configuration file is /home/osmc/.hyperion/config/hyperion_main.json\n
It could be edited manually; but the web based GUI is recommended on port :8090 of your server for all configuration.\n
\n
It should be possible to start/stop the Hyperion daemon server with:\n
sudo systemctl <start/stop> hyperion.service\n
\n
Make the daemon server start automatically at boot with:\n
sudo systemctl <enable/disable> hyperion.service\n
\n
The Hyperion Remote control app in the Google Play Store now appears to be working with ng again.\n
There is also an experimental app you can try from:\n
https://github.com/BioHaZard1/hyperion-android" 0 0
}



####################
# EXECUTION BEGINS #
####################

# check for dialog
depends_check dialog

if [ ${#missing_depends[@]} -gt 0 ]; then
    clear
    echo -e "\n\n*****\nFor first time use I need to install:\n\n${missing_depends[@]}\n\nPlease wait...\n**********\n\n"
    sleep 3
    sudo apt-get install -y dialog
fi

# start main menu
while true; do
    exec 3>&1
    selection=$(dialog \
        --backtitle "Hyperion.ng Setup on Vero4K" \
        --title "Hyperion.ng" \
        --clear \
        --cancel-label "Quit" \
        --item-help \
        --menu "Please select:" 0 0 4 \
        "1" "Install from binary" "Install from binary" \
        "2" "Build from source" "Build from source" \
        "3" "Uninstall" "Uninstall" \
        "4" "Post Installation" "Post Installation" \
        2>&1 1>&3)
    ret_val=$?
    exec 3>&-

    case $ret_val in
        $DIALOG_CANCEL)
            clear
            echo "Program cancelled."
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
			install_from_binary
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
