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

#############
# VARIABLES #
#############

REPO_DIR=$(pwd)
edition=()
tag=()
build_advice=()
post_advice=()
msg_list=()

declare -a LINK_LIST=(/usr/bin/flatc /usr/bin/flathash /usr/bin/gpio2spi /usr/bin/hyperion-aml /usr/bin/hyperion-framebuffer /usr/bin/hyperion-remote /usr/bin/hyperion-v4l2 /usr/bin/hyperiond /usr/bin/protoc)
declare -a PREBUILD_DEPENDS=(git cmake build-essential)
declare -a build_depends
declare -a run_depends
declare -a fatal_depends
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

function install_relative() {
    # all operations wil be relative to the current working directory, so must be set correctly before calling

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

    # copy over configs with backup of the previous config to avoid disappointment
    # bit dirty - uses the fact that cp and rm ignore folders without the --recursive option...
    waitbox "PROGRESS" "Installing configuration files"
    go ../../config
    if [ -d /etc/hyperion ]; then
        stamp=$(date +'%Y-%m-%d_%H%M%S')
        # create a time stamped backup folder
        sudo mkdir /etc/hyperion/backup_$stamp
        # then copy over anything that is not a folder
        cp /etc/hyperion/* /etc/hyperion/backup_$stamp
        # then remove anything that is not a folder
        rm /etc/hyperion/*
        # tell somebody what we've done
        waitbox "PROGRESS" "The previous configuration files have been moved to /etc/hyperion/backup_$stamp"
        sleep 3
    else
        sudo mkdir /etc/hyperion
    fi
    sudo cp * /etc/hyperion

    # (re)make effects folders and copy over
    waitbox "PROGRESS" "Installing effects"
    go ../effects
    sudo mkdir /usr/share/hyperion/effects
    sudo cp * /usr/share/hyperion/effects

    # copy over systemd script and register
    waitbox "PROGRESS" "Registering hyperion service"
    go ../bin/service
    sudo cp $systemd_unit /etc/systemd/system/hyperion.service
    sudo systemctl daemon-reload

    # return to base
    cd ../../..

    # install runtime dependancies
    waitbox "PROGRESS" "Checking for missing runtime dependancies"
    depends_install ${run_depends[@]}

    dialog --backtitle "Hyperion$tag Setup on Vero4K - Installation" --title "PROGRESS" --msgbox "INSTALLATION COMPLETED!\n\nStart hyperion with:\nsudo systemctl start hyperion\n\nPlease check the post-installation page - you've still got a lot to do..." 0 0
}


function build_from_source() {
    if (! dialog --backtitle "Hyperion$tag Setup on Vero4K - Build from source" --title "PROCEED?" --defaultno --no-label "Abort" --yesno "This will delete previous build files and folders.\n\nIt will attempt to preserve old configs..." 0 0); then
        return
    fi

    # configure build environment - particularly it avoids floating point runtime error
    export CFLAGS="-I/opt/vero3/include -L/opt/vero3/lib -O3 -march=armv8-a+crc -mtune=cortex-a53 -mfpu=neon-fp-armv8 -mfloat-abi=hard -ftree-vectorize -funsafe-math-optimizations"
    export CPPFLAGS=$CFLAGS
    export CXXFLAGS=$CFLAGS

    # check and get prebuild dependancies
    waitbox "PROGRESS" "Checking for missing pre-build dependancies"
    depends_install ${PREBUILD_DEPENDS[@]}

    # clone the source repo
    waitbox "Git Clone" "Downloading the Hyperion$tag project repository"
    if [ -d ./source_$edition ]; then
        rm -r source_$edition
    fi
    git clone --recursive $repo_url source_$edition
    go source_$edition

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
    done <<< "$(sudo cmake -L 2>/dev/null | grep BOOL)"

    # run checklist dialog
    cmd=(dialog --clear --backtitle "Hyperion$tag Setup on Vero4K - Build from source" --title "BUILD OPTIONS" --checklist "Press SPACE to toggle options:" 15 40 7)
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
    depends_install ${build_depends[@]}

    # compile hyperion
    waitbox "Compiling Hyperion$tag" "This will take quite a while, so I'll show you the output to keep you posted..."; sleep 2;
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
    waitbox "Harmful Dependancies" "Uninstalling:\n${fatal_depends[@]}"
    sudo apt-get remove -y ${fatal_depends[@]}
    sudo apt-get autoremove -y

    # install everything
    cd ../..
    install_relative
}


function uninstall() {
    # chance to back out
    if (! dialog --backtitle "Hyperion$tag Setup on Vero4K - Uninstall" --title "PROCEED?" --defaultno --no-label "Abort" --yesno "This will delete all installed binaries and effects." 0 0); then
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
    if (dialog --backtitle "Hyperion$tag Setup on Vero4K - Uninstall" --title "CONFIGURATION FILES!" --defaultno --yes-label "Delete" --no-label "Keep" --yesno "Would you like to DELETE the config files as well?" 0 0); then
        # delete configs
        sudo rm -r /etc/hyperion
        waitbox "PROGRESS" "Configuration files deleted"
    fi
    dialog --backtitle "Hyperion$tag Setup on Vero4K - Uninstall" --title "PROGRESS" --msgbox "FINISHED!\n\nHyperion$tag has been uninstalled" 0 0
}


function post_installation() {
  dialog --title "Hyperion$tag: Post Installation Advice" \
    --no-collapse \
    --msgbox \
    "$post_advice" 0 0
}


function options_menu() {
    while true; do
        exec 3>&1
        selection=$(dialog \
            --backtitle "Hyperion$tag Setup on Vero4K" \
            --title "Hyperion$tag" \
            --clear \
            --cancel-label "Back" \
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
                break
                ;;
            $DIALOG_ESC)
                clear
                break
                ;;
        esac

        case $selection in
            0 )
                clear
                echo "Program terminated @004." #004
                ;;
            1 )
                dialog --backtitle "Hyperion$tag Setup on Vero4K - Install from binary" --title "Advice" --msgbox \
"This will install a prebuilt version of Hyperion$tag with all of the Vero4K compatible compilation options enabled.\n
\n
Of course this will use a little more file space and possibly more CPU resources, for features you may not need.\n
\n\
It will also be an older version, so consider building from source once you've tried things out." 0 0

                if (dialog --backtitle "Hyperion$tag Setup on Vero4K - Install from binary" --title "PROCEED?" --defaultno --no-label "Abort" --yesno "This will delete any previous build files and folders you may have.\n\nIt will attempt to preserve old configs..." 0 0); then
                    cd $REPO_DIR/hyperion_$edition/prebuilt_$edition
                    install_relative
                fi
                ;;
            2 )
                dialog --backtitle "Hyperion$tag Setup on Vero4K - Build from source" --title "Advice" --msgbox "$build_advice" 0 0
                cd $REPO_DIR/hyperion_$edition
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
        --backtitle "Hyperion Setup on Vero4K - Main Menu" \
        --title "Main Menu" \
        --clear \
        --cancel-label "Exit" \
        --item-help \
        --menu "Please select:" 0 0 2 \
        "1" "Hyperion \"classic\"" "The original version of Hyperion." \
        "2" "Hyperion.ng" "The pre-alpha development version of Hyperion.  Fun fact: \".ng\" stands for Next Generation.  I did not know that." \
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
            # configure installer for hyperion "classic"
            edition='classic'
            tag=' "classic"'
            build_depends=(qt5-default libusb-1.0-0-dev libpython3.5-dev)
            run_depends=(libqt5core5a libqt5gui5 libqt5widgets5 libqt5network5 libusb-1.0-0 libpython3.5)
            fatal_depends=(qt5-default)
            systemd_unit='hyperion.systemd.sh'
            repo_url='https://github.com/hyperion-project/hyperion.git'

            build_advice='This software is intended for the Vero4K running OSMC, therefore options relating to:\n
\n
  1. The Raspberry Pi (dispmanx),\n
  2. An X environment,\n
  3. An Apple/OSX setup\n
\n
are unsupported - likely failing to build.\n
\n
*** You are recommended at this time to ENABLE QT5 ***\n
\n
Feel free to use this script as a starting point for your own installer on another platform.  This is open-source afterall.'

            post_advice='Please refer to the Hyperion wiki for configuration advice.\n
https://hyperion-project.org/wiki/Main\n
\n
The configuration file is in /etc/hyperion/\n
Although it can be edited manually the Java based GUI is recommended:\n
hypercon.jar (try SourceForge)\n
\n
It should be possible to start/stop the Hyperion daemon server with:\n
sudo systemctl <start/stop> hyperion.service\n
\n
Also look out for the Hyperion remote control app in the Google Play Store.'

            options_menu
            ;;
        2 )
            # configure installer for hyperion.ng
            edition='nextgen'
            tag='.ng'
            build_depends=(vero3-userland-dev-osmc qtbase5-dev libqt5serialport5-dev libusb-1.0-0-dev libpython3.5-dev libxrender-dev libavahi-core-dev libavahi-compat-libdnssd-dev libmbedtls-dev libpcre3-dev zlib1g-dev)
            run_depends=(libqt5concurrent5 libqt5core5a libqt5dbus5 libqt5gui5 libqt5network5 libqt5printsupport5 libqt5serialport5 libqt5sql5 libqt5test5 libqt5widgets5 libqt5xml5 libusb-1.0-0 libpython3.5 qt5-qmake)
            fatal_depends=(libegl1-mesa)
            systemd_unit='hyperion.systemd'
            repo_url='https://github.com/hyperion-project/hyperion.ng.git'

            build_advice='This software is intended for the Vero4K running OSMC, therefore options relating to:\n
\n
  1. The Raspberry Pi (dispmanx),\n
  2. An X environment,\n
  3. An Apple/OSX setup\n
\n
are unsupported - likely failing to build.\n
\n
*** You are recommended at this time to ENABLE QT5 and DISABLE Tests ***\n
\n
Feel free to use this script as a starting point for your own installer on another platform.  This is open-source afterall.'

            post_advice='Please refer to the Hyperion wiki for configuration advice.\n
https://hyperion-project.org/wiki/Main\n
\n
There is also some experience on the OSMC forum, specifically the "OSMC and Hyperion" thread in the Vero4k section.\n
\n
The configuration file is in /etc/hyperion/\n
Although it can be edited manually the web based GUI is recommended on port :8090 of your server.\n
\n
It should be possible to start/stop the Hyperion daemon server with:\n
sudo systemctl <start/stop> hyperion.service\n
\n
The Hyperion Remote control app in the Google Play Store now appears to be working with ng again.\n
There is also an experimental app you can try from:\n
https://github.com/BioHaZard1/hyperion-android'

            options_menu
        ;;
    esac
done

