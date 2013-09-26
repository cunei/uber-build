#!/bin/bash -e

if [ -n "$DEBUG" ]
then
  set -x
fi

# Initialize file descriptors. May be modified later.
exec 6>&1 7>&1

#################################################################
# Unification script
#
# This script was created to support multiple test cases:
# * generating Scala IDE + plugins releases
# * being run during Scala PR validation
# * being run locally to reproduce Scala PR validation results
# * run every night to check the script itself
#
# Main features:
# * rebuilds and cache each piece as required
# * gets instructions from a 'config' file
##################################################################

# temp dir were all 'non-build' operation are performed
TMP_ROOT_DIR=$(mktemp -d -t uber-build.XXXX)
TMP_DIR=${TMP_ROOT_DIR}/tmp
TMP_CACHE_DIR=${TMP_ROOT_DIR}/cacheLink
mkdir ${TMP_DIR}

# Timestamp used for logging and marking zip files
TIMESTAMP=`date '+%Y%m%d-%H%M'`

# ant options. The Scala build needs a fair amount of memory
export ANT_OPTS="-Xms512M -Xmx2048M -Xss1M -XX:MaxPermSize=128M"

####################
# logging functions
####################

# Logging about step being performed
# $1 - title
function printStep () {
  echo ">>>>> $1" >&6
}

# General logging
# $* - message
function info () {
  echo ">> $*" >&6
}

# Debug logging for variable
# $1 - variable name
function debugValue () {
  echo "----- $1=${!1}"
}

# General debug logging
# $* - message
function debug () {
  echo "----- $*"
}

# General error logging
# $* - message
function error () {
  echo "!!!!! $*" >&2
  exit 3
}

# Error logging for wrong variable value
# $1 - variable name
# $2 - possible choices
function missingParameterChoice () {
  echo "!!!!! Bad value for $1. Was '${!1}', should be one of: $2." >&2
  exit 2
}

#########
# Checks
#########

# Check if the given parameters are defined
# $* - parameter names to check non-empty
function checkParameters () {
  for i in $*
  do
    if [ -z "${!i}" ]
    then
      echo "!!!!! Bad value for $i. It should be defined." >&2
      exit 2
    fi
  done
}

# Check if an artifact is available
# $1 - groupId
# $2 - artifacId
# $3 - version
# $4 - extra repository to look in (optional)
# return value in $RES
function checkAvailability () {
  cd ${TMP_DIR}
  rm -rf *

# pom file for the test project
  cat > pom.xml << EOF
<project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/maven-v4_0_0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.typesafe</groupId>
  <artifactId>typesafeDummy</artifactId>
  <packaging>war</packaging>
  <version>1.0-SNAPSHOT</version>
  <name>Dummy</name>
  <url>http://127.0.0.1</url>
  <dependencies>
    <dependency>
      <groupId>$1</groupId>
      <artifactId>$2</artifactId>
      <version>$3</version>
    </dependency>
  </dependencies>
EOF

  if [ -n "$4" ]
  then
# adds the extra repository
    cat >> pom.xml << EOF
  <repositories>
    <repository>
      <id>extrarepo</id>
      <name>extra repository</name>
      <url>$4</url>
    </repository>
  </repositories>
EOF
  fi

  cat >> pom.xml << EOF
</project>
EOF

  # TODO: DEBUGGGING !!!!!

  which mvn
  alias mvn

  set +e

  which mvn
  alias mvn

  mvn $MAVEN_OPTS compile
  RES=$?
  set -e

# log the result
  if [ ${RES} == 0 ]
  then
    debug "$1:$2:jar:$3 found !"
  else
    debug "$1:$2:jar:$3 not found !"
  fi
}

# Like check availability, but fail if not available.
# $1 - groupId
# $2 - artifactId
# $3 - version
# $4 - extra repository (optional)
function checkNeeded () {
  checkAvailability "$1" "$2" "$3" "$4"
  if [ ${RES} != 0 ]
  then
    error "$1:$2:jar:$3 is needed !!!"
  fi
}

# Check if the given executable is in the PATH.
# $1 - executable
# return value in $RES
function checkExecutableOnPath () {
  set +e
  BIN_LOCATION=$(which $1)
  RES=$?
  set -e
}

########################
# p2 repo cache support
########################

# Check if a p2 repo is available in the cache.
# $1 - p2 cache id
# return value in $RES
function checkP2Cache () {
  if ${WITH_CACHE}
  then
    if [ -d ${P2_CACHE_DIR}/$1 ]
    then
      debug "$1 found !"
      RES=0
    else
      debug "$1 not found !"
      RES=1
    fi
  else
    debug "caching disabled"
    RES=1
  fi
}

# Store a p2 repo in the cache.
# $1 - p2 cache id
# $2 - repo to cache
function storeP2Cache () {
  if ${WITH_CACHE}
  then
    mkdir -p $(dirname ${P2_CACHE_DIR}/$1)
    cp -r $2 ${P2_CACHE_DIR}/$1
    debug "$1 cached !"
  else
# only caching the original location
    mkdir -p ${TMP_CACHE_DIR}/$1
    echo -n $2 > ${TMP_CACHE_DIR}/$1/link
  fi
}

# Return the location in the file system of the cached p2 repo.
# $1 - p2 cache id
function getP2CacheLocation () {
  if ${WITH_CACHE}
  then
    echo ${P2_CACHE_DIR}/$1
  else
    cat ${TMP_CACHE_DIR}/$1/link
  fi
}

# Merge a p2 repo into an other one.
# $1 - repository to merge
# $2 - location to merge it to
function mergeP2Repo () {
  BUILD_TOOLS_DIR=${BUILD_DIR}/build-tools
  fetchGitBranch $BUILD_TOOLS_DIR "git://github.com/scala-ide/build-tools.git" master

  cd $BUILD_TOOLS_DIR/maven-tool/merge-site/
  mvn $MAVEN_OPTS -Drepo.source="$1" -Drepo.dest="$2" package
}

############
# m2 + osgi
############

# Extract the osgi version from the MANIFEST.MF file
# of an artifact available in the local m2 repo.
# $1 - groupId
# $2 - artifactId
# $3 - version
function osgiVersion () {
  cd ${TMP_DIR}
  rm -rf *
  unzip -q "${LOCAL_M2_REPO}/${1//\.//}/$2/$3/$2-$3.jar"
  # used \r as an extra field separator, to avoid problem with Windows style new lines.
  grep Bundle-Version META-INF/MANIFEST.MF | awk -F '[ \r]' '{printf $2;}'
}

##############
# GIT support
##############

# Checkout the given branch. Clone and fetch the remote repo as needed.
# $1 - local dir
# $2 - remote repo
# $3 - branch, tag or hash
# $4 - depth (TODO: really needed?)
# $5 - extra fetch (optional)
function fetchGitBranch () {
  if [ ! -d $1 ]
  then
    info "Cloning git repo $2"
    REMOTE_ID="remote01"
    git clone -o ${REMOTE_ID} $2 $1
    cd $1
  else
    cd $1
    # check if the remote repo is already defined
    REMOTE_ID=$(git config --get-regexp 'remote.*.url' | grep "$2" | awk -F '.' '{print $2;}')
    if [ -z "${REMOTE_ID}" ]
    then
      info "Adding remote git repo $2"
      LAST_REMOTE_ID=$(git config --get-regexp 'remote.remote*.url' | awk -F '.' '{print $2;}' | sort | tail -1)
      NEW_INDEX=$(( ${LAST_REMOTE_ID:6} + 1 ))
      REMOTE_ID="remote"$(printf '%02d' ${NEW_INDEX})
      git remote add ${REMOTE_ID} $2
    fi
    info "Fetching update for $2"
    git fetch ${REMOTE_ID}
  fi

  # add extra fetch config if needed
  if [ -n "$5" ]
  then
    FETCH_STRING="+refs/pull/*/head:refs/remotes/${REMOTE_ID}/$5/*"
    if git config --get-all "remote.${REMOTE_ID}.fetch" | grep -Fc "${FETCH_STRING}"
    then
      :
    else
      info "Add extra fetch config"
      git config --add "remote.${REMOTE_ID}.fetch" ${FETCH_STRING}
      git fetch ${REMOTE_ID}
    fi
  fi

  info "Checking out $3"
  git checkout -f -q $3

}

##################
##################
# The build steps
##################
##################

##################
# Check arguments
##################

# $1 - error message
function printErrorUsageAndExit () {
  echo "$1" >&2
  echo "Usage:" >&2
  echo "  $0 <config_file>" >&2
  exit 1
}

# $* - arguments
function stepCheckArguments () {
  printStep "Check arguments"

  if [ 1 != $# ]
  then
    printErrorUsageAndExit "Wrong arguments"
  fi

  CONFIG_FILE=$1
  if [ ! -f ${CONFIG_FILE} ]
  then
    printErrorUsageAndExit "'${CONFIG_FILE}' doesn't exists or is not a file"
  fi
}

####################
# Build parameters
####################

function stepLoadConfig () {
  printStep "Load config"

# set the working folders
  CURRENT_DIR=$(pwd)
  SCRIPT_DIR=$(cd "$( dirname "$0" )" && pwd)

# load the default parameters

  . ${SCRIPT_DIR}/config/default.conf

# load the config

  . ${CONFIG_FILE}
}

################
# Setup logging
################

function stepSetupLogging () {
  printStep "Setup logging"

  if [ -z "${DEBUG}" ]
# enable in file logging only if not in debug mode
  then
    case "${LOGGING}" in
      file )
        LOG_FILE=${BUILD_DIR}/log-${TIMESTAMP}.txt
        > ${LOG_FILE}
        exec 3>> ${LOG_FILE} 4>&1 5>&2 6>&1

        exec 1>&3 2> >(tee -a /dev/fd/3 >&5) 6> >(tee -a /dev/fd/3 >&4)
        ;;
      console)
        ;;
      * )
        missingParameterChoice "LOGGING" "file, console"
        ;;
    esac
  fi
}

############
# Set flags
############

function stepSetFlags () {
  printStep "Set flags"

# the flags
  RELEASE=false
  DRY_RUN=true
  VALIDATOR=false
  SCALA_REBUILD=false
  SIGN_ARTIFACTS=false
  WORKSHEET_PLUGIN=false
  PLAY_PLUGIN=false
  SEARCH_PLUGIN=false
  PUBLISH=false

# Check what to do
  case ${OPERATION} in
    release )
      RELEASE=true
      DRY_RUN=false
      SIGN_ARTIFACTS=true
      ;;
    release-dryrun )
      RELEASE=true
      DRY_RUN=true
      SIGN_ARTIFACTS=true
      ;;
    nightly )
      RELEASE=true
      DRY_RUN=true
      SIGN_ARTIFACTS=false
      ;;
    scala-pr-validator )
      VALIDATOR=true
      ;;
    scala-pr-rebulid )
      VALIDATOR=true
      SCALA_REBUILD=true
      ;;
    * )
      missingParameterChoice "OPERATION" "release, release-dryrun, scala-pr-validator, scala-pr-rebulid"
      ;;
  esac

  if ${RELEASE}
  then
# Check the plugins to build.
    for PLUGIN in ${PLUGINS}
    do
      case ${PLUGIN} in
        worksheet )
          WORKSHEET_PLUGIN=true
          ;;
        play )
          PLAY_PLUGIN=true
          ;;
        search )
          SEARCH_PLUGIN=true
          ;;
        * )
          error "Unknown value in PLUGINS. Should be one of: worksheet play search."
      esac
    done

# Check the type of release.
    case ${BUILD_TYPE} in
      dev | stable )
        if ${DRY_RUN}
        then
          PUBLISH=false
        else
          PUBLISH=true
        fi
        ;;
      * )
        missingParameterChoice "PUBLISH" "dev, stable"
        ;;
    esac
  fi

# Check the cache flag
  case ${WITH_CACHE} in
    true | false )
      ;;
    * )
      missingParameterChoice "WITH_CACHE" "true, false"
      ;;
  esac
}

#################
# Pre-requisites
#################

function stepCheckPrerequisites () {
  printStep "Check prerequisites"

  JAVA_VERSION=$(java -version 2>&1 | grep 'java version' | awk -F '"' '{print $2;}')
  JAVA_SHORT_VERSION=${JAVA_VERSION:0:3}
  if [ "1.6" != "${JAVA_SHORT_VERSION}" ]
  then
    error "Please run the script with Java 1.6. Current version is: ${JAVA_VERSION}."
  fi

# ant is need to rebuild Scala
  if ${SCALA_REBUILD}
  then
    if [ -n "${ANT}" ]
    then
      if [ -x "${ANT}" ]
      then
        ${ANT}
      else
        error "The variable ANT is set, but doesn't point to an executable."
      fi
    else
      checkExecutableOnPath "ant"
      if [ "${RES}" != 0 ]
      then
        error "To be able to rebuild a special version of Scala, 'ant' should be in the PATH, or the variable ANT should be set"
      fi
    fi
  fi

# eclipse and keytool are needed to sign the jars
  if ${SIGN_ARTIFACTS}
  then
    checkExecutableOnPath "keytool"
    if [ "${RES}" != 0 ]
    then
      error "keytool is required on PATH to sign the jars"
    fi

    if [ -n "${ECLIPSE}" ]
    then
      if [ -x "${ECLIPSE}" ]
      then
        export ECLIPSE="${ECLIPSE}"
      else
        error "The variable ECLIPSE is set, but doesn't point to an executable."
      fi
    else
      checkExecutableOnPath "eclipse"
      if [ "${RES}" != 0 ]
      then
        error "to sign the jars, 'eclipse' should be in the PATH, or the variable ECLIPSE should be set."
      else
        export ECLIPSE=$(which eclipse)
      fi
    fi
  fi
}

######################
# Check configuration
######################

# Checks that all needed parameters are correctly defined.
function stepCheckConfiguration () {
  printStep "Check configuration"

  checkParameters "SCRIPT_DIR" "BUILD_DIR" "LOCAL_M2_REPO" "P2_CACHE_DIR"

# configure maven here. Needed for some checks
  MAVEN_OPTS="-U -Dmaven.repo.local=${LOCAL_M2_REPO}"

  mkdir -p ${BUILD_DIR}

  if ${RELEASE}
  then
    checkParameters "SCALA_VERSION"
  fi

  if ${VALIDATOR}
  then
    checkParameters "SCALA_GIT_REPO" "SCALA_VERSION" "SCALA_GIT_HASH" "SCALA_DIR"
    checkParameters "ZINC_BUILD_DIR" "ZINC_BUILD_GIT_REPO" "ZINC_BUILD_GIT_BRANCH"
  fi

  checkParameters "SBT_VERSION"

  checkParameters "ECLIPSE_PLATFORM"
  checkParameters "SCALA_IDE_DIR" "SCALA_IDE_GIT_REPO" "SCALA_IDE_GIT_BRANCH" "SCALA_IDE_VERSION_TAG"
  checkParameters "SCALA_REFACTORING_DIR" "SCALA_REFACTORING_GIT_REPO" "SCALA_REFACTORING_GIT_BRANCH"
  checkParameters "SCALARIFORM_DIR" "SCALARIFORM_GIT_REPO" "SCALARIFORM_GIT_BRANCH"

  if ${WORKSHEET_PLUGIN}
  then
    checkParameters "WORKSHEET_PLUGIN_DIR" "WORKSHEET_PLUGIN_GIT_REPO" "WORKSHEET_PLUGIN_GIT_BRANCH" "WORKSHEET_PLUGIN_VERSION_TAG"
  fi

  if ${PLAY_PLUGIN}
  then
    checkParameters "PLAY_PLUGIN_DIR" "PLAY_PLUGIN_GIT_REPO" "PLAY_PLUGIN_GIT_BRANCH" "PLAY_PLUGIN_VERSION_TAG"
  fi

  if ${SEARCH_PLUGIN}
  then
    checkParameters "SEARCH_PLUGIN_DIR" "SEARCH_PLUGIN_GIT_REPO" "SEARCH_PLUGIN_GIT_BRANCH" "SEARCH_PLUGIN_VERSION_TAG"
  fi

  if ${PRODUCT}
  then
    checkParameters "PRODUCT_DIR" "PRODUCT_GIT_REPO" "PRODUCT_GIT_BRANCH" "PRODUCT_VERSION_TAG"
  fi

  if ${SIGN_ARTIFACTS}
  then
    checkParameters "KEYSTORE_DIR" "KEYSTORE_PASS"

    cd $CURRENT_DIR
    cd $KEYSTORE_DIR
    KEYSTORE_DIR=$(pwd)

# clone the keystore repo. Needed to check if the pass is fine.
    if [ ! -d "${KEYSTORE_DIR}" ]
    then
      checkParameters "KEYSTORE_GIT_REPO"

      fetchGitBranch "${KEYSTORE_DIR}" "${KEYSTORE_GIT_REPO}" master
    fi

    keytool -list -keystore "${KEYSTORE_DIR}/typesafe.keystore" -storepass "${KEYSTORE_PASS}" -alias typesafe

    MAVEN_SIGN_ARGS=" -Djarsigner.storepass=${KEYSTORE_PASS} -Djarsigner.keypass=${KEYSTORE_PASS} -Djarsigner.keystore=${KEYSTORE_DIR}/typesafe.keystore "
  fi

# set extra variables. There are different ways to reference the Scala and Eclipse versions.
  case ${SCALA_VERSION} in
    2.10.* )
      SCALA_PROFILE="scala-2.10.x"
      SCALA_REPO_SUFFIX="210x"
      ECOSYSTEM_SCALA_VERSION="scala210"
      ;;
    2.11.* )
      SCALA_PROFILE="scala-2.11.x"
      SCALA_REPO_SUFFIX="211x"
      ECOSYSTEM_SCALA_VERSION="scala211"
      ;;
    * )
      error "Not supported version of Scala: ${SCALA_IDE_DIR}."
      ;;
  esac

  case ${ECLIPSE_PLATFORM} in
    indigo )
      ECLIPSE_PROFILE="eclipse-indigo"
      ECOSYSTEM_ECLIPSE_VERSION="e37"
      ;;
    juno )
      ECLIPSE_PROFILE="eclipse-juno"
      ECOSYSTEM_ECLIPSE_VERSION="e38"
      ;;
    * )
      error "Not supported eclipse platform: ${ECLIPSE_PLATFORM}."
      ;;
  esac
}

########
# Scala
########

function stepScala () {
  printStep "Scala"

# for releases, already existing Scala binaries are used.
  if ${RELEASE}
  then
    checkNeeded "org.scala-lang" "scala-compiler" "${SCALA_VERSION}"
    FULL_SCALA_VERSION=${SCALA_VERSION}

    SCALA_UID=$(osgiVersion "org.scala-lang" "scala-compiler" "${SCALA_VERSION}")
  fi

# for Scala pr validation, custom build Scala binaries are used.
  if ${VALIDATOR}
  then
    FULL_SCALA_VERSION="${SCALA_VERSION}-${SCALA_GIT_HASH}-SNAPSHOT"
    SCALA_VERSION_SUFFIX="-$SCALA_GIT_HASH-SNAPSHOT"
    checkAvailability "org.scala-lang" "scala-compiler" "${FULL_SCALA_VERSION}"
    if [ $RES != 0 ]
    then
      # the scala build is not available locally. check in scala-webapps.
      HTTP_STATUS=$(curl --write-out %{http_code} --silent --output /dev/null "http://scala-webapps.epfl.ch/artifacts/${SCALA_GIT_HASH}/")
      if [ ${HTTP_STATUS} == 200 ]
      then
        info "Deploying Scala version from scala-webapps"
        cd $TMP_DIR
        rm -rf *
        wget "http://scala-webapps.epfl.ch/artifacts/${SCALA_GIT_HASH}/maven.tgz"
        tar xf maven.tgz
        cd latest
        ant \
          -Dmaven.version.number="${FULL_SCALA_VERSION}" \
          -Dlocal.snapshot.repository="${LOCAL_M2_REPO}" \
          -Dmaven.version.suffix="${SCALA_VERSION_SUFFIX}" \
          deploy.local

        checkNeeded "org.scala-lang" "scala-compiler" "${FULL_SCALA_VERSION}"
      else
        if ! ${SCALA_REBUILD}
        then
          error "Scala binaries with git hash ${SCALA_GIT_HASH} were not found on scala-webapps, and will not be rebuilt locally."
        fi

        info "Building Scala from source"

        fetchGitBranch "${SCALA_DIR}" "${SCALA_GIT_REPO}" "${SCALA_GIT_HASH}" NaN "pr"

        cd ${SCALA_DIR}

        ant -Divy.cache.ttl.default=eternal all.clean
        git clean -fxd
        ant \
          distpack-maven-opt \
          -Darchives.skipxz=true \
          -Dlocal.snapshot.repository="${LOCAL_M2_REPO}" \
          -Dversion.suffix="${SCALA_VERSION_SUFFIX}"

        cd dists/maven/latest
        ant \
          -Dlocal.snapshot.repository="${LOCAL_M2_REPO}" \
          -Dmaven.version.suffix="-${SCALA_VERSION_SUFFIX}" \
          deploy.local

        checkNeeded "org.scala-lang" "scala-compiler" "${FULL_SCALA_VERSION}"
      fi
    fi
    SCALA_UID=${SCALA_GIT_HASH}
  fi
  SHORT_SCALA_VERSION=$(echo ${FULL_SCALA_VERSION} | awk -F '.' '{print $1"."$2;}')
}

#######
# Zinc
#######

function stepZinc () {
  printStep "Zinc"

  FULL_SBT_VERSION="${SBT_VERSION}-on-${FULL_SCALA_VERSION}-for-IDE-SNAPSHOT"

# for releases, already existing sbt binaries are used.
  if ${RELEASE}
  then
    IDE_M2_REPO="http://typesafe.artifactoryonline.com/typesafe/ide-${SHORT_SCALA_VERSION}"
    checkNeeded "com.typesafe.sbt" "incremental-compiler" "${FULL_SBT_VERSION}" "${IDE_M2_REPO}"
  fi

# for Scala pr validation, custom build sbt binaries are used.
  if ${VALIDATOR}
  then
    checkAvailability "com.typesafe.sbt" "incremental-compiler" "${FULL_SBT_VERSION}"
    if [ $RES != 0 ]
    then
      info "Building Zinc using dbuild"

      fetchGitBranch "${ZINC_BUILD_DIR}" "${ZINC_BUILD_GIT_REPO}" "${ZINC_BUILD_GIT_BRANCH}" NaN

      cd "${ZINC_BUILD_DIR}"

      SCALA_VERSION="${FULL_SCALA_VERSION}" \
        PUBLISH_REPO="file://${LOCAL_M2_REPO}" \
        LOCAL_M2_REPO="${LOCAL_M2_REPO}" \
        bin/dbuild sbt-on-${SHORT_SCALA_VERSION}.x

      checkNeeded "com.typesafe.sbt" "incremental-compiler" "${FULL_SBT_VERSION}"
    fi
  fi

  SBT_UID=${FULL_SBT_VERSION}
}

##################
# Build toolchain
##################

function stepToolchain () {
  printStep "Build toolchain"

  fetchGitBranch "${SCALA_IDE_DIR}" "${SCALA_IDE_GIT_REPO}" "${SCALA_IDE_GIT_BRANCH}" NaN

  cd ${SCALA_IDE_DIR}

  SCALA_IDE_UID=$(git rev-parse HEAD)

  BUILD_TOOLCHAIN_P2_ID=toolchain/${SCALA_IDE_UID}/${SCALA_UID}/${SBT_UID}

  checkP2Cache ${BUILD_TOOLCHAIN_P2_ID}
  if [ $RES != 0 ]
  then
    info "building toolchain"

    MAVEN_ARGS="-P${ECLIPSE_PROFILE} -P${SCALA_PROFILE} -Psbt-new -Dscala.version=${FULL_SCALA_VERSION} -Dsbt.version=${SBT_VERSION} -Dsbt.ide.version=${FULL_SBT_VERSION}"

    mvn ${MAVEN_OPTS} ${MAVEN_ARGS} clean install 1>/dev/null 2>&1

    cd ${SCALA_IDE_DIR}/org.scala-ide.build-toolchain
    mvn ${MAVEN_OPTS} ${MAVEN_ARGS} clean install 1>/dev/null 2>&1

    cd ${SCALA_IDE_DIR}/org.scala-ide.toolchain.update-site
    mvn ${MAVEN_OPTS} ${MAVEN_ARGS} clean verify 1>/dev/null 2>&1

    cd ${TMP_DIR}
    rm -rf *
    mkdir fakeSite
    cp -r ${SCALA_IDE_DIR}/org.scala-ide.toolchain.update-site/org.scala-ide.scala.update-site/target/site fakeSite/scala-eclipse-toolchain-osgi-${SCALA_REPO_SUFFIX}

    storeP2Cache ${BUILD_TOOLCHAIN_P2_ID} ${TMP_DIR}/fakeSite
  fi
}

####################
# Scala Refactoring
####################

function stepScalaRefactoring () {
  printStep "Scala Refactoring"

  fetchGitBranch "${SCALA_REFACTORING_DIR}" "${SCALA_REFACTORING_GIT_REPO}" "${SCALA_REFACTORING_GIT_BRANCH}" NaN

  cd ${SCALA_REFACTORING_DIR}

  SCALA_REFACTORING_UID=$(git rev-parse HEAD)

  SCALA_REFACTORING_P2_ID=scala-refactoring/${SCALA_REFACTORING_UID}/${SCALA_IDE_UID}/${SCALA_UID}

  checkP2Cache ${SCALA_REFACTORING_P2_ID}
  if [ $RES != 0 ]
  then
    info "Building Scala Refactoring"

    mvn ${MAVEN_OPTS} \
      -P ${SCALA_PROFILE} \
      -Dscala.version=${FULL_SCALA_VERSION} \
      -Drepo.scala-ide=file://$(getP2CacheLocation ${BUILD_TOOLCHAIN_P2_ID}) \
      -Dgit.hash=${SCALA_REFACTORING_UID} \
      clean \
      verify

    storeP2Cache ${SCALA_REFACTORING_P2_ID} ${SCALA_REFACTORING_DIR}/org.scala-refactoring.update-site/target/site
  fi
}

##############
# Scalariform
##############

function stepScalariform () {
  printStep "Scalariform"

  fetchGitBranch "${SCALARIFORM_DIR}" "${SCALARIFORM_GIT_REPO}" "${SCALARIFORM_GIT_BRANCH}" NaN

  cd ${SCALARIFORM_DIR}

  SCALARIFORM_UID=$(git rev-parse HEAD)

  SCALARIFORM_P2_ID=scalariform/${SCALARIFORM_UID}/${SCALA_IDE_UID}/${SCALA_UID}

  checkP2Cache ${SCALARIFORM_P2_ID}
  if [ $RES != 0 ]
  then
    info "Building Scalariform"

    mvn ${MAVEN_OPTS} \
      -P ${SCALA_PROFILE} \
      -Dscala.version=${FULL_SCALA_VERSION} \
      -Drepo.scala-ide=file://$(getP2CacheLocation ${BUILD_TOOLCHAIN_P2_ID}) \
      -Dgit.hash=${SCALARIFORM_UID} \
      clean \
      verify

    storeP2Cache ${SCALARIFORM_P2_ID} ${SCALARIFORM_DIR}/scalariform.update/target/site
  fi
}

############
# Scala IDE
############

function stepScalaIDE () {
  printStep "Scala IDE"

  cd ${SCALA_IDE_DIR}

  if $SIGN_ARTIFACTS
  then
    SCALA_IDE_P2_ID=scala-ide/${SCALA_IDE_UID}-S/${SCALA_UID}/${SBT_UID}/${SCALA_REFACTORING_UID}/${SCALARIFORM_UID}
  else
    SCALA_IDE_P2_ID=scala-ide/${SCALA_IDE_UID}/${SCALA_UID}/${SBT_UID}/${SCALA_REFACTORING_UID}/${SCALARIFORM_UID}
  fi

  checkP2Cache ${SCALA_IDE_P2_ID}
  if [ $RES != 0 ]
  then
    info "Building Scala IDE"

    if $RELEASE
    then
      # TODO: remove the condition. The only reason it is here is because the tool
      # is not able to correctly read long Scala version string of MANIFEST.MF :(
      export SET_VERSIONS=true
    fi

    ./build-all.sh \
      ${MAVEN_OPTS} \
      -P${ECLIPSE_PROFILE} \
      -P${SCALA_PROFILE} \
      -Psbt-new \
      -Dscala.version=${FULL_SCALA_VERSION} \
      -Dversion.tag=${SCALA_IDE_VERSION_TAG} \
      -Dsbt.version=${SBT_VERSION} \
      -Dsbt.ide.version=${FULL_SBT_VERSION} \
      -Drepo.scala-refactoring=file://$(getP2CacheLocation ${SCALA_REFACTORING_P2_ID}) \
      -Drepo.scalariform=file://$(getP2CacheLocation ${SCALARIFORM_P2_ID}) \
      clean \
      install

    cd ${SCALA_IDE_DIR}/org.scala-ide.sdt.update-site

    if $SIGN_ARTIFACTS
    then
      ./plugin-signing.sh ${KEYSTORE_DIR}/typesafe.keystore typesafe ${KEYSTORE_PASS} ${KEYSTORE_PASS}
    fi

    storeP2Cache ${SCALA_IDE_P2_ID} ${SCALA_IDE_DIR}/org.scala-ide.sdt.update-site/target/site
  fi
}

##################
# Plugin
##################

# $1 - pretty name
# $2 - logic name
# $3 - var prefix
# $4 - repo dir
# $5 - git repo
# $6 - git branch
# $7 - version tag
function stepPlugin () {
  printStep "$1"

  fetchGitBranch $4 $5 $6 NaN

  cd $4

  P_UID=$(git rev-parse HEAD)

  eval $3_UID=${P_UID}

  P2_ID=$2/${P_UID}/${SCALA_IDE_UID}/${SCALA_UID}

  eval $3_P2_ID=${P2_ID}

  checkP2Cache ${P2_ID}
  if [ $RES != 0 ]
  then
    info "Building $1"


    mvn ${MAVEN_OPTS} \
      -Dtycho.localArtifacts=ignore \
      -Pset-versions \
      -P${ECLIPSE_PROFILE} \
      -P${SCALA_PROFILE} \
      -Drepo.scala-ide=file://$(getP2CacheLocation ${SCALA_IDE_P2_ID}) \
      -Dscala.version=${FULL_SCALA_VERSION} \
      -Dtycho.style=maven \
      --non-recursive \
      exec:java

    mvn ${MAVEN_OPTS} \
      -Dtycho.localArtifacts=ignore \
      -P${ECLIPSE_PROFILE} \
      -P${SCALA_PROFILE} \
      -Drepo.scala-ide=file://$(getP2CacheLocation ${SCALA_IDE_P2_ID}) \
      -Dscala.version=${FULL_SCALA_VERSION} \
      -Dversion.tag=$7 \
      ${MAVEN_SIGN_ARGS} \
      clean \
      verify

    storeP2Cache ${P2_ID} *update-site/target/site
  fi
}

###########
# Product
###########

function stepProduct () {
  printStep "Product"

  fetchGitBranch ${PRODUCT_DIR} ${PRODUCT_GIT_REPO} ${PRODUCT_GIT_BRANCH} NaN

  cd ${PRODUCT_DIR}

  PRODUCT_UID=$(git rev-parse HEAD)

  PRODUCT_P2_ID=product/${PRODUCT_UID}/${SCALA_IDE_UID}/${SCALA_UID}

  if ${WORKSHEET_PLUGIN}
  then
    PRODUCT_P2_ID=${PRODUCT_P2_ID}/W-${WORKSHEET_PLUGIN_UID}
  fi

  if ${PLAY_PLUGIN}
  then
    PRODUCT_P2_ID=${PRODUCT_P2_ID}/P-${PLAY_PLUGIN_UID}
  fi

  if ${SEARCH_PLUGIN}
  then
    PRODUCT_P2_ID=${PRODUCT_P2_ID}/S-${SEARCH_PLUGIN_UID}
  fi

  checkP2Cache ${PRODUCT_P2_ID}
  if [ $RES != 0 ]
  then
    info "Generate merged update site for Product build"

    rm -rf ${TMP_DIR}/*
    PRODUCT_BUILD_P2_REPO=${TMP_DIR}/p2-repo-for-product

    cp -r $(getP2CacheLocation ${SCALA_IDE_P2_ID}) ${PRODUCT_BUILD_P2_REPO}

    if ${WORKSHEET_PLUGIN}
    then
      mergeP2Repo $(getP2CacheLocation ${WORKSHEET_PLUGIN_P2_ID}) ${PRODUCT_BUILD_P2_REPO}
    fi

    if ${PLAY_PLUGIN}
    then
      mergeP2Repo $(getP2CacheLocation ${PLAY_PLUGIN_P2_ID}) ${PRODUCT_BUILD_P2_REPO}
    fi

    if ${SEARCH_PLUGIN}
    then
      mergeP2Repo $(getP2CacheLocation ${SEARCH_PLUGIN_P2_ID}) ${PRODUCT_BUILD_P2_REPO}
    fi

    info "Build Product"

    cd ${PRODUCT_DIR}

    REPO_PATH_ECLIPSE="/sdk/${ECOSYSTEM_ECLIPSE_VERSION}"
    REPO_PATH_SCALA="/${ECOSYSTEM_SCALA_VERSION}/${BUILD_TYPE}/site"

    mvn ${MAVEN_OPTS}\
      -Dtycho.localArtifacts=ignore \
      --non-recursive \
      -Pconfigure \
      -P${SCALA_PROFILE} \
      -P${ECLIPSE_PLATFORM} \
      -Dversion.tag=${PRODUCT_VERSION_TAG} \
      -Dscala.version=${FULL_SCALA_VERSION} \
      -Drepopath.platform="${REPO_PATH_ECLIPSE}" \
      -Drepopath.scala-ide.ecosystem="${REPO_PATH_SCALA}" \
      process-resources

    mvn ${MAVEN_OPTS} \
      -Dtycho.localArtifacts=ignore  \
      -P${SCALA_PROFILE} \
      -P${ECLIPSE_PLATFORM} \
      -Dversion.tag=${PRODUCT_VERSION_TAG} \
      -Dscala.version=${FULL_SCALA_VERSION} \
      -Drepopath.scala-ide.ecosystem="" \
      -Drepopath.platform="" \
      -Drepo.scala-ide.root="file://${PRODUCT_BUILD_P2_REPO}" \
      ${MAVEN_SIGN_ARGS} \
      clean \
      package

    storeP2Cache ${PRODUCT_P2_ID} ${PRODUCT_DIR}/org.scala-ide.product/target/repository
  fi
}

##########
# Publish
##########

# $1 - pretty name
# $2 - logic name
# $3 - var prefix
function publishPlugin () {
  info "uploading $1"

  cd ${TMP_DIR}
  rm -rf *
  P2_ID_VAR_NAME=$3_P2_ID
  cp -r $(getP2CacheLocation ${!P2_ID_VAR_NAME}) site
  ZIP_NAME=site-${TIMESTAMP}.zip
  zip -rq ${ZIP_NAME} site

  PLUGIN_UPLOAD_DIR="scala-ide.dreamhosters.com/plugins/$2/release/${ECOSYSTEM_ECLIPSE_VERSION}/${SHORT_SCALA_VERSION}.x"
  scp ${ZIP_NAME} ${SSH_ACCOUNT}:${PLUGIN_UPLOAD_DIR}
  ssh ${SSH_ACCOUNT} "cd ${PLUGIN_UPLOAD_DIR}; rm -rf site; unzip -q ${ZIP_NAME}"

}

function stepPublish () {
  printStep "Publish"

#  SSH_ACCOUNT="scalaide@scala-ide.dreamhosters.com"
  SSH_ACCOUNT="luc@localhost"

  info "generate base ecosystem repo"

  rm -rf ${TMP_DIR}/*
  ECOSYSTEM_P2_REPO=${TMP_DIR}/p2-repo-for-ecosystem
  mkdir -p ${ECOSYSTEM_P2_REPO}

  cp -r $(getP2CacheLocation ${SCALA_IDE_P2_ID}) ${ECOSYSTEM_P2_REPO}/base

  if ${PRODUCT}
  then
    mergeP2Repo $(getP2CacheLocation ${PRODUCT_P2_ID}) ${ECOSYSTEM_P2_REPO}/base
  fi

  info "uploading base ecosystem"

  cd ${ECOSYSTEM_P2_REPO}

  ZIP_NAME=base-${TIMESTAMP}.zip
  zip -qr ${ZIP_NAME} base

  ECOSYSTEM_UPLOAD_DIR="scala-ide.dreamhosters.com/sdk/next/${ECOSYSTEM_ECLIPSE_VERSION}/${ECOSYSTEM_SCALA_VERSION}/${BUILD_TYPE}"
  scp ${ZIP_NAME} ${SSH_ACCOUNT}:${ECOSYSTEM_UPLOAD_DIR}
  ssh ${SSH_ACCOUNT} "cd ${ECOSYSTEM_UPLOAD_DIR}; rm -rf base; unzip -q ${ZIP_NAME}"

  if ${WORKSHEET}
  then
    publishPlugin "Worksheet" "worksheet" "WORKSHEET_PLUGIN"
  fi

  if ${PLAY}
  then
    publishPlugin "Play" "scala-ide-play2" "PLAY_PLUGIN"
  fi

  if ${SEARCH}
  then
    publishPlugin "Search" "scala-search" "SEARCH_PLUGIN"
  fi

}

##############
##############
# MAIN SCRIPT
##############
##############

stepCheckArguments $*

stepLoadConfig
stepSetupLogging
stepSetFlags

stepCheckPrerequisites
stepCheckConfiguration

stepScala

stepZinc
stepToolchain
stepScalaRefactoring
stepScalariform

stepScalaIDE

if ${WORKSHEET_PLUGIN}
then
  stepPlugin "Scala Worksheet" "worksheet" "WORKSHEET_PLUGIN" "${WORKSHEET_PLUGIN_DIR}" "${WORKSHEET_PLUGIN_GIT_REPO}" "${WORKSHEET_PLUGIN_GIT_BRANCH}" "${WORKSHEET_PLUGIN_VERSION_TAG}"
fi

if ${PLAY_PLUGIN}
then
  stepPlugin "Play" "play" "PLAY_PLUGIN" "${PLAY_PLUGIN_DIR}" "${PLAY_PLUGIN_GIT_REPO}" "${PLAY_PLUGIN_GIT_BRANCH}" "${PLAY_PLUGIN_VERSION_TAG}"
fi

if ${SEARCH_PLUGIN}
then
  stepPlugin "Scala Search" "search" "SEARCH_PLUGIN" "${SEARCH_PLUGIN_DIR}" "${SEARCH_PLUGIN_GIT_REPO}" "${SEARCH_PLUGIN_GIT_BRANCH}" "${SEARCH_PLUGIN_VERSION_TAG}"
fi

if ${PRODUCT}
then
  stepProduct
fi

if ${PUBLISH}
then
  stepPublish
fi

######
# END
######

printStep "Build succesful"
