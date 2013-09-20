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
  mvn $MAVEN_OPTS compile
#  mvn $MAVEN_OPTS compile > /dev/null 2>&1
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
# $2 - artifacId
# $3 - version
# $4 - extra repository (optional)
function checkNeeded () {
  checkAvailability "$1" "$2" "$3" "$4"
  if [ ${RES} != 0 ]
  then
    error "$1:$2:jar:$3 is needed !!!"
  fi
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
  git checkout -q $3

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

case ${OPERATION} in
  release )
    RELEASE=true
    ;;
  release-dryrun )
    RELEASE=true
    DRY_RUN=true
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
  set +e
  ANT_BIN=`which ant`
  RES=$?
  set -e
  if [ "${RES}" != 0 ]
  then
    error "Ant is required to use a special version of Scala"
  fi
fi

######################
# Check configuration
######################

printStep "Check configuration"

checkParameters "SCRIPT_DIR" "BUILD_DIR" "LOCAL_M2_REPO"

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

########
# Scala
########

printStep "Scala"

if ${RELEASE}
then
  checkNeeded "org.scala-lang" "scala-compiler" "${SCALA_VERSION}"
  FULL_SCALA_VERSION=${SCALA_VERSION}
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

    fetchGitBranch "${ZINC_BUILD_DIR}" "${ZINC_BUILD_GIT_REPO}" "${ZINC_BUILD_GIT_BRANCH}"

    cd "${ZINC_BUILD_DIR}"

    SCALA_VERSION="${FULL_SCALA_VERSION}" \
      PUBLISH_REPO="file://${LOCAL_M2_REPO}" \
      LOCAL_M2_REPO="${LOCAL_M2_REPO}" \
      bin/dbuild sbt-on-${SHORT_SCALA_VERSION}.x

    checkNeeded "com.typesafe.sbt" "incremental-compiler" "${FULL_SBT_VERSION}"
  fi
fi

##################
# Build toolchain
##################

printstep "Build toolchain"

######
# END
######

printStep "Build succesful"
