#!/bin/bash

echo
############################################
echo "### Set Variables ###"
############################################
if [ ! -z ${EPK_VERSION} ]; then
	if [ -z `echo ${EPK_VERSION} | grep -P "^\d\.\d\d\.\d\d$"` ]; then 
		echo "version string NG!!"
		exit 1  # error injection for making build failure..
	fi;
	echo EPK_VERSION=${EPK_VERSION}
fi;
echo BRANCH=${BRANCH}
echo MACHINE=${MACHINE}

BUILD_TYPE=`echo ${JOB_NAME} | cut -d'-' -f3`
echo BUILD_TYPE=${BUILD_TYPE}

RUN_TYPE=`echo ${JOB_NAME} | cut -d'_' -f1`
echo RUN_TYPE=${RUN_TYPE}

if [ ! -z `echo ${JOB_NAME} | grep "hotel"` ]; then 
	PRODUCT_TYPE="commercial"
	if [ -z ${REGION} ]; then 
		echo "ERROR: You must select at least one region.."
		exit 1  # error injection for making build failure..
	fi;
	echo REGION=${REGION}
else 
	PRODUCT_TYPE="signage"
	REGION="atsc"
fi;
echo PRODUCT_TYPE=${PRODUCT_TYPE}

BUILD_IMAGES=""
for region in `echo ${REGION} | sed "s/,/ /g"`; do
	BUILD_IMAGES+="starfish-${region}-flash starfish-${region}-flash-devel "
	if [ ${BUILD_TYPE} = "official" ] || [ ${GERRIT_TOPIC}_ = "USB"_ ]; then
		BUILD_IMAGES+="starfish-${region}-secured starfish-${region}-nfs "
	fi;
done
if [ ${PRODUCT_TYPE} = "signage" ]; then
	BUILD_IMAGES=`echo ${BUILD_IMAGES} | sed "s/atsc-//g" | sed "s/nfs/atsc-nfs/g"`
fi;
echo BUILD_IMAGES=${BUILD_IMAGES}

if [ ${BUILD_TYPE} = "official" ]; then 
	export WEBOS_DISTRO_BUILD_ID=${BUILD_NUMBER}
	echo WEBOS_DISTRO_BUILD_ID=${WEBOS_DISTRO_BUILD_ID}

	echo DEV_SIZE=${DEV_SIZE}
	if [ ! -z ${DEV_LOC} ]; then 
		echo DEV_LOC=${DEV_LOC}
		DEV_LOC+="_"; 
	fi;
	if [ ! -z ${DEV_NAME} ]; then 
		echo DEV_NAME=${DEV_NAME}
		DEV_NAME+="_"; 
	fi;
	echo RAWIMG_CMD=${RAWIMG_CMD}
fi;

# hongyj - Add different official and verify job path.
BUILD_DIRECTORY="/home/jenkins/${BUILD_TYPE}"
[ ${BUILD_TYPE} = "official" ] && BUILD_DIRECTORY+="/${JOB_NAME}"
echo BUILD_DIRECTORY=${BUILD_DIRECTORY}

if [ ! -z `echo ${BRANCH#@} | grep drd` ]; then
	META_ID_LOC=meta-lg-webos-tv
    IMAGE_HOME="${BUILD_DIRECTORY}/build-starfish/BUILD/deploy/images/${MACHINE}"
	BUILD_HISTORY_DIR=${BUILD_DIRECTORY}/build-starfish/buildhistory/images/${MACHINE}/glibc
else
	META_ID_LOC=meta-lg-webos
    IMAGE_HOME="${BUILD_DIRECTORY}/build-starfish/BUILD-${MACHINE}/deploy/images/"
	BUILD_HISTORY_DIR=${BUILD_DIRECTORY}/build-starfish/buildhistory/images/${MACHINE}/eglibc
fi
echo META_ID_LOC=${META_ID_LOC}
echo IMAGE_HOME=${IMAGE_HOME}
echo BUILD_HISTORY_DIR=${BUILD_HISTORY_DIR}

BUILD_HISTORY_FILE="build-id.txt image-info.txt files-in-image.txt installed-packages.txt installed-package-sizes.txt installed-package-file-sizes.txt"
echo BUILD_HISTORY_FILE=${BUILD_HISTORY_FILE}

echo
############################################
echo "### output Binary Server ###"
############################################
BUILD_ARTIFACTS_IP="10.178.87.74"

BUILD_MCF_RSYNC_ROOT="file:///mnt/build-artifacts-${PRODUCT_TYPE}/id"
BUILD_MCF_PREMIRROR="--premirror=$BUILD_MCF_RSYNC_ROOT/downloads"

BUILD_MCF_SSTATEMIRROR=""
if [ ${RUN_TYPE} = "TEST" ] || [ ${BUILD_TYPE} = "verify" ]; then 
	BUILD_MCF_SSTATEMIRROR="--sstatemirror=$BUILD_MCF_RSYNC_ROOT/`echo ${JOB_NAME} | cut -d'-' -f2 | cut -d'.' -f2`/sstate-cache"
fi;

BUILD_MCF_BITBAKE_THREADS="-b 24"
BUILD_MCF_MAKE_THREADS="-p 24"

mkdir -p ${BUILD_DIRECTORY}
cd ${BUILD_DIRECTORY}
echo Current directory : `pwd`
echo Now deleting build-starfish..
rm -rf build-starfish

git clone ssh://we.lge.com/id/starfish/build-starfish -b ${BRANCH}
echo Changing Directory to build-starfish.
cd build-starfish

echo
############################################
### cherry-pick patchset (build-starfish layer) ###
############################################
if [ ${BUILD_TYPE} = "verify" ] && [ ${GERRIT_PROJECT} = "id/starfish/build-starfish" ]; then
	echo "### cherry-pick patchset (build-starfish layer) ###"
	git fetch ssh://we.lge.com/${GERRIT_PROJECT} $GERRIT_REFSPEC && git checkout FETCH_HEAD
fi

echo
############################################
echo "### update meta layers ###"
############################################
echo "./mcf ${BUILD_MCF_BITBAKE_THREADS} ${BUILD_MCF_MAKE_THREADS} ${MACHINE} ${BUILD_MCF_PREMIRROR} ${BUILD_MCF_SSTATEMIRROR}"
time ./mcf ${BUILD_MCF_BITBAKE_THREADS} ${BUILD_MCF_MAKE_THREADS} ${MACHINE} ${BUILD_MCF_PREMIRROR} ${BUILD_MCF_SSTATEMIRROR}

echo
############################################
### cherry-pick patchset ( ${META_ID_LOC} layer) ###
############################################
if [ ${BUILD_TYPE} = "verify" ] && [ ! -z `echo ${GERRIT_PROJECT} | grep ${META_ID_LOC}` ] ; then
	echo "### cherry-pick patchset (${META_ID_LOC} layer) ###"
	pushd `basename ${GERRIT_PROJECT}`
	git fetch ssh://we.lge.com/${GERRIT_PROJECT} $GERRIT_REFSPEC && git checkout FETCH_HEAD
	popd
fi

echo
############################################
### update version , app history ###
############################################
if [ ! -z ${EPK_VERSION} ]; then 
	echo "### update version , app history ###"
	pushd ${META_ID_LOC}/meta-id/conf/distro
	echo "WEBOS_DISTRO_MANUFACTURING_VERSION = \"0${EPK_VERSION}\""
	echo "WEBOS_DISTRO_MANUFACTURING_VERSION = \"0${EPK_VERSION}\"" >> starfish4id.conf
	popd
fi;

echo
############################################
echo "### Build image ###"
############################################
echo make ${BUILD_IMAGES}
time make ${BUILD_IMAGES}
if [ $? != 0 ]; then
  exit 1
fi

echo
################################################
echo "### Populate image ###"
################################################
POPULATE_HOME=/home/apache_home/id-image/${JOB_NAME}/${BUILD_NUMBER}

pushd ${IMAGE_HOME}
for build_images in ${BUILD_IMAGES}; do
	ssh buildmaster@${BUILD_ARTIFACTS_IP} mkdir -p ${POPULATE_HOME}/${build_images}/buildhistory
	SRC_IMG=`find . -type f -name "${build_images}-${MACHINE}-*"`
	for i in ${SRC_IMG}; do
		if [ ${BUILD_TYPE} = "verify" ]; then
			DEST_IMG=`echo $i | sed -r "s/[0-9]{14}/verify-${BUILD_NUMBER}/g"`
		else
			DEST_IMG=""
		fi;
		echo "scp -rp $i buildmaster@${BUILD_ARTIFACTS_IP}:${POPULATE_HOME}/${build_images}/${DEST_IMG}"
		scp -rp $i buildmaster@${BUILD_ARTIFACTS_IP}:${POPULATE_HOME}/${build_images}/${DEST_IMG}
	done
done
popd

echo
################################################
### populate raw image ###
################################################
if [ ${BUILD_TYPE} = "official" ]; then 
	echo "### Populate raw image ###"
	TEMP_IMAGE="temp.bin"
	CKSUM_TOOL="calc_byte_cksum"
	RAWIMG_TOOL=`echo ${RAWIMG_CMD} | cut -d' ' -f1`
	echo RAWIMG_TOOL=${RAWIMG_TOOL}

	pushd ${IMAGE_HOME}
	wget http://${BUILD_ARTIFACTS_IP}/utils/${PRODUCT_TYPE}/${RAWIMG_TOOL} && chmod a+x ${RAWIMG_TOOL}
	wget http://${BUILD_ARTIFACTS_IP}/utils/${PRODUCT_TYPE}/${CKSUM_TOOL} && chmod a+x ${CKSUM_TOOL}

	for region in `echo ${REGION} | sed "s/,/ /g"`; do
		region+="-"
		if [ ${PRODUCT_TYPE} = "signage" ]; then 
			region=""
		fi;
		STARFISH_IMAGE=`find . -type f -name "starfish-${region}flash-${MACHINE}-*.epk"`
		./${RAWIMG_CMD} -p ${STARFISH_IMAGE} ${STARFISH_IMAGE}.bin
		BYTE_CKSUM=`./${CKSUM_TOOL} ${DEV_SIZE} ${STARFISH_IMAGE}.bin`
		IMAGE_PREFIX=`basename ${STARFISH_IMAGE} ".squashfs.epk" | sed "s/flash-//g" | sed "s/-/_/g"`

		RENAMED_IMAGE="${IMAGE_PREFIX}_0x${BYTE_CKSUM}_${DEV_LOC}${DEV_NAME}`date +%y%m%d`"

		echo "scp -r ${STARFISH_IMAGE}.bin buildmaster@${BUILD_ARTIFACTS_IP}:/home/apache_home/id-image/${JOB_NAME}/${BUILD_NUMBER}/starfish-${region}flash/${RENAMED_IMAGE}.bin"
		scp -r ${STARFISH_IMAGE}.bin buildmaster@${BUILD_ARTIFACTS_IP}:/home/apache_home/id-image/${JOB_NAME}/${BUILD_NUMBER}/starfish-${region}flash/${RENAMED_IMAGE}.bin
	done
	popd
fi;

echo
################################################
### make ezi file ###
################################################

# webOS2.0 use ota epk 
# webOS3.0 use nsu epk
# Add condition webOs3.0 making ezi file

if [ ${PRODUCT_TYPE} = "commercial" ] && [ ${BUILD_TYPE} = "official" ]; then 	
	echo "### make ezi files ###"
    SPLIT_PREFIX="SP"
	SPLIT_TEMP="tmp"

	pushd ${IMAGE_HOME}
	for region in `echo ${REGION} | sed "s/,/ /g"`; do
		EPK_TYPE=ota
		[ ! -z `echo ${BRANCH#@} | grep drd` ] && EPK_TYPE=nsu

		SRC_EPK=`find . -type f -name "starfish-${region}-secured-${MACHINE}-*${EPK_TYPE}*" -exec basename {} \;`
		EZI_EPK=`echo ${SRC_EPK/${EPK_TYPE}/ezi}`

	    split --verbose -d -b 90M ${SRC_EPK} ${SPLIT_PREFIX} | sed -r "s/.*${SPLIT_PREFIX}([0-9]{2})./\1/g" | sed -r "s/0*([0-9]+)/\1/g" > ${SPLIT_TEMP}

		SPLIT_MAX_NUM=`cat ${SPLIT_TEMP} | tail -1`
		for i in `cat ${SPLIT_TEMP}`; do
			mv ${SPLIT_PREFIX}`printf "%02d" $i` ${SPLIT_PREFIX}`printf "%02d" $(($i+1))`_$(($SPLIT_MAX_NUM+1))_${EZI_EPK}
		done
		zip -v ${SPLIT_PREFIX} `ls ${SPLIT_PREFIX}*`
		scp -r ${SPLIT_PREFIX}.zip buildmaster@${BUILD_ARTIFACTS_IP}:/home/apache_home/id-image/${JOB_NAME}/${BUILD_NUMBER}/starfish-${region}-secured/${EZI_EPK/epk/zip}
		rm -f ${SPLIT_PREFIX}*
	done
	popd
fi;

echo
################################################
echo "### Copy History files ###"
################################################

for build_images in ${BUILD_IMAGES}; do
	for history_files in ${BUILD_HISTORY_FILE}; do
		echo "scp -r ${BUILD_HISTORY_DIR}/${build_images}/${history_files} buildmaster@${BUILD_ARTIFACTS_IP}:${POPULATE_HOME}/${build_images}/buildhistory/${history_files}"
		scp -r ${BUILD_HISTORY_DIR}/${build_images}/${history_files} buildmaster@${BUILD_ARTIFACTS_IP}:${POPULATE_HOME}/${build_images}/buildhistory/${history_files}
	done
done

echo
############################################
### Making tags ###
############################################
if [ ! ${RUN_TYPE} = "TEST" ] && [ ${BUILD_TYPE} = "official" ]; then 
	echo "### Making tags ###"
	pushd ${BUILD_DIRECTORY}/build-starfish
	git tag -a builds/${BRANCH#@}/${BUILD_NUMBER} -m "builds/${BRANCH#@}/${BUILD_NUMBER}"
	git push origin builds/${BRANCH#@}/${BUILD_NUMBER}

	cd ${META_ID_LOC} 
	echo "tagging builds/starfish/${BRANCH#@}/${BUILD_NUMBER} on ${META_ID_LOC}"
	git tag -a builds/starfish/${BRANCH#@}/${BUILD_NUMBER} -m "builds/starfish/${BRANCH#@}/${BUILD_NUMBER}"
	git push origin builds/starfish/${BRANCH#@}/${BUILD_NUMBER}
	popd
fi;

echo
############################################
### Extract CCC list ###
############################################
CCC_LIST=${WORKSPACE}/ccc.lst
if [ ${BUILD_TYPE} = "official" ]; then 
	echo "### Extract CCC list ###"
	pushd ${BUILD_DIRECTORY}/build-starfish
	CCC_HASH_TABLE=`git log -n 1 | grep -P " [0-9,a-z]{7} " | cut -d' ' -f5`
	cd ${META_ID_LOC} 
	[ -f ${CCC_LIST} ] && rm ${CCC_LIST}
	for list in ${CCC_HASH_TABLE}
	do
		CCC=`git log -n 1 $list | grep -P "\s.+\[.+\]\s?CCC\s?:" | sed -r "s/\s{4}//g"`
		[ -z "${CCC}" ] && CCC=`git log -n 1 $list --oneline`
		printf "${CCC}\n\n" >> ${CCC_LIST}
	done
	popd
fi;
echo "<< extraced ccc list >>"
cat ${CCC_LIST}
echo "---------------------------"

echo
###########################################
### Set build properites for JENKINS ###
###########################################
echo "### Set build properites for JENKINS ###"
BUILD_PROP=${WORKSPACE}/build.properties
[ -f ${BUILD_PROP} ] && rm ${BUILD_PROP}
echo CCC_LIST=${CCC_LIST} >> ${BUILD_PROP}
