#!/bin/bash -e

if [ -n "$DEBUG" ]
then
  set -x
fi

#################################################################
# Unification script
# 
# This script was created to support 3 test cases:
# * generating Scala IDE + plugins releases
# * being run during Scala PR validation
# * being run locally to reproduce Scala PR validation results
#
# Main features:
# * rebuilds and cache each piece as required
# * gets instructions from a 'config' file
##################################################################

TMP_DIR=$(mktemp -d -t uber-build.XXXX)
export ANT_OPTS="-Xms512M -Xmx2048M -Xss1M -XX:MaxPermSize=128M"

# $1 - title
function printStep () {
  echo ">>>>> $1"
}

# $* - message
function info () {
  echo ">> $*"
}

# $1 - parameter name
function debugValue () {
  echo "----- $1=${!1}"
}

# $* - message
function debug () {
  echo "----- $*"
}

# $* - message
function error () {
  echo "!!!!! $*"
  exit 3
}

# $1 - parameter name
# $2 - possible choices
function missingParameterChoice () {
  echo "Bad value for $1. Was '${!1}', should be one of: $2." >&2
  exit 2
}

# $* - parameter names to check non-empty
function checkParameters () {
  for i in $*
  do
    if [ -z "${!i}" ]
    then
      echo "Bad value for $i. It should be defined." >&2
      exit 2
    fi
  done
}

# $1 - groupId
# $2 - artifacId
# $3 - version
# $4 - extra repository (optional)
# return value in $RES
function checkAvailability () {
  cd ${TMP_DIR}
  rm -rf *
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
  # TODO push in real log
  set +e
#  mvn $MAVEN_OPTS compile
  mvn $MAVEN_OPTS compile > /dev/null 2>&1
  RES=$?
  set -e
  if [ ${RES} == 0 ]
  then
    debug "$1:$2:jar:$3 found !"
  else
    debug "$1:$2:jar:$3 not found !"
  fi
}

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

# $1 - p2 cache id
# return value in $RES
function checkP2Cache () {
  if [ -d ${P2_CACHE_DIR}/$1 ]
  then
    debug "$1 found !"
    RES=0
  else
    debug "$1 not found !"
    RES=1
  fi
}

# $1 - p2 cache id
# $2 - repo to cache
function storeP2Cache () {
  mkdir -p $(dirname ${P2_CACHE_DIR}/$1)
  cp -r $2 ${P2_CACHE_DIR}/$1
  debug "$1 cached !"
}

# $1 - p2 cache id
function getP2CacheLocation () {
  echo ${P2_CACHE_DIR}/$1
}

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

# $1 - executable
# return value in $RES
function checkExecutableOnPath () {
  set +e
  BIN_LOCATION=$(which $1)
  RES=$?
  set -e
}

##############
# GIT support
##############

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

##############
##############
# MAIN SCRIPT
##############
##############

##################
# Check arguments
##################

printStep "Check arguments"

# $1 - error message
function printErrorUsageAndExit () {
  echo "$1" >&2
  echo "Usage:" >&2
  echo "  $0 <config_file>" >&2
  exit 1
}

if [ 1 != $# ]
then
  printErrorUsageAndExit "Wrong arguments"
fi

CONFIG_FILE=$1
if [ ! -f ${CONFIG_FILE} ]
then
  printErrorUsageAndExit "'${CONFIG_FILE}' doesn't exists or is not a file"
fi

####################
# Build parameters
####################

printStep "Load config"

SCRIPT_DIR=$(cd "$( dirname "$0" )" && pwd)
CURRENT_DIR=$(pwd)

# Load the default parameters

. ${SCRIPT_DIR}/config/default.conf

# Load the config

. ${CONFIG_FILE}

############
# Set flags
############

printStep "Set flags"

# flags
RELEASE=false
DRY_RUN=false
VALIDATOR=false
SIGN_ARTIFACTS=false

case ${OPERATION} in
  release )
    RELEASE=true
    SIGN_ARTIFACTS=true
    ;;
  release-dryrun )
    RELEASE=true
    DRY_RUN=true
    SIGN_ARTIFACTS=true
    ;;
  scala-validator )
    VALIDATOR=true
    ;;
  * )
    missingParameterChoice "OPERATION" "release, release-dryrun, scala-validator"
    ;;
esac

#################
# Pre-requisites
#################

printStep "Check prerequisites"

JAVA_VERSION=$(java -version 2>&1 | grep 'java version' | awk -F '"' '{print $2;}')
JAVA_SHORT_VERSION=${JAVA_VERSION:0:3}
if [ "1.6" != "${JAVA_SHORT_VERSION}" ]
then
  error "Please run the script with Java 1.6. Current version is: ${JAVA_VERSION}."
fi

if $VALIDATOR
then
  checkExecutableOnPath ant
  if [ "${RES}" != 0 ]
  then
    error "Ant is required to use a special version of Scala"
  fi
fi

######################
# Check configuration
######################

printStep "Check configuration"

checkParameters "SCRIPT_DIR" "BUILD_DIR" "LOCAL_M2_REPO" "P2_CACHE_DIR"

mkdir -p ${BUILD_DIR}

# configure maven here. Needed for some checks
MAVEN_OPTS="-e -U -Dmaven.repo.local=${LOCAL_M2_REPO}"

if ${RELEASE}
then
  checkParameters "SCALA_VERSION"
fi 

if ${VALIDATOR}
then
  checkParameters "SCALA_GIT_REPO" "SCALA_VERSION" "SCALA_GIT_HASH" "SCALA_DIR"
  checkParameters "ZINC_BUILD_DIR" "ZINC_BUILD_GIT_REPO" "ZINC_BUILD_GIT_BRANCH"
fi

checkParameters "SCALA_IDE_DIR" "SCALA_IDE_GIT_REPO" "SCALA_IDE_GIT_BRANCH"
checkParameters "ECLIPSE_PLATFORM" "VERSION_TAG"
checkParameters "SCALA_REFACTORING_DIR" "SCALA_REFACTORING_GIT_REPO" "SCALA_REFACTORING_GIT_BRANCH"
checkParameters "SCALARIFORM_DIR" "SCALARIFORM_GIT_REPO" "SCALARIFORM_GIT_BRANCH"

if ${SIGN_ARTIFACTS}
then
  checkExecutableOnPath "keytool"
  if [ "${RES}" != 0 ]
  then
    error "keytool is required on PATH to sign the jars"
  fi
  checkExecutableOnPath "eclipse"
  if [ "${RES}" != 0 ]
  then
    error "eclipse is required on PATH to sign the jars"
  fi

  checkParameters "KEYSTORE_DIR" "KEYSTORE_PASS"
  if [ ! -d "${KEYSTORE_DIR}" ]
  then
    checkParameters "KEYSTORE_GIT_REPO"

    fetchGitBranch "${KEYSTORE_DIR}" "${KEYSTORE_GIT_REPO}" master
  fi

  keytool -list -keystore "${KEYSTORE_DIR}/typesafe.keystore" -storepass "${KEYSTORE_PASS}" -alias typesafe
fi

case ${SCALA_VERSION} in 
  2.10.* )
    SCALA_PROFILE="scala-2.10.x"
    SCALA_REPO_SUFFIX="210x"
    ;;
  2.11.* )
    SCALA_PROFILE="scala-2.11.x"
    SCALA_REPO_SUFFIX="211x"
    ;;
  * )
    error "Not supported version of Scala: ${SCALA_IDE_DIR}."
    ;;
esac

case ${ECLIPSE_PLATFORM} in
  indigo )
    ECLIPSE_PROFILE="eclipse-indigo"
    ;;
  juno )
    ECLIPSE_PROFILE="eclipse-juno"
    ;;
  * )
    error "Not supported eclipse platform: ${ECLIPSE_PLATFORM}."
    ;;
esac

########
# Scala
########

printStep "Scala"

if ${RELEASE}
then
  checkNeeded "org.scala-lang" "scala-compiler" "${SCALA_VERSION}"
  FULL_SCALA_VERSION=${SCALA_VERSION}

  SCALA_UID=$(osgiVersion "org.scala-lang" "scala-compiler" "${SCALA_VERSION}")
fi

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

#######
# Zinc
#######

printStep "Zinc"

FULL_SBT_VERSION="${SBT_VERSION}-on-${FULL_SCALA_VERSION}-for-IDE-SNAPSHOT"

if ${RELEASE}
then
  IDE_M2_REPO="http://typesafe.artifactoryonline.com/typesafe/ide-${SHORT_SCALA_VERSION}"
  checkNeeded "com.typesafe.sbt" "incremental-compiler" "${FULL_SBT_VERSION}" "${IDE_M2_REPO}"
fi

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

##################
# Build toolchain
##################

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

####################
# Scala Refactoring
####################

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

##############
# Scalariform
##############

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

############
# Scala IDE
############

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
    -Dversion.tag=${VERSION_TAG} \
    -Dsbt.version=${SBT_VERSION} \
    -Dsbt.ide.version=${FULL_SBT_VERSION} \
    -Drepo.scala-refactoring=file://$(getP2CacheLocation ${SCALA_REFACTORING_P2_ID}) \
    -Drepo.scalariform=file://$(getP2CacheLocation ${SCALARIFORM_P2_ID}) \
    clean \
    install

  cd ${SCALA_IDE_DIR}/org.scala-ide.sdt.update-site

  ./plugin-signing.sh ${KEYSTORE_DIR}/typesafe.keystore typesafe ${KEYSTORE_PASS} ${KEYSTORE_PASS}

  storeP2Cache ${SCALA_IDE_P2_ID} ${SCALA_IDE_DIR}/org.scala-ide.sdt.update-site/target/site
fi
  

######
# END
######

printStep "Build succesful"
