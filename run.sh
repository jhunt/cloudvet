#!/bin/bash
exec 2>&1
if ! file cloudvet | grep -q ELF; then
	gox -osarch linux/amd64 -output cloudvet
fi

cf_wait_for() { # {{{
	set +e
	while true; do
		local space=$(cat ~/.cf/config.json | jq -r '.SpaceFields.GUID')
		if [[ -z $space ]]; then
			echo 2>&1 "no space targeted."
			exit 1
		fi
		local state="not found"
		local guid=$(cf curl /v2/spaces/$space/service_instances | jq -r '.resources[] | select(.entity.name == "'$1'") | .metadata.guid')
		if [[ -n $guid ]]; then
			local state=$(cf curl /v2/service_instances/$guid | jq -r '.entity.last_operation.state')
		fi
		case $state in
		(*progress)
			sleep 5
			;;
		(*)
			set -e
			return 0
			;;
		esac
	done
} # }}}

exec 2>&1
cat <<EOF

   ..:: cloudvet testing services ::..

Thank you for choosing cloudvet for all your
testing needs.  We are honored to serve you.

First, we're going to run a pre-flight check,
to validate the sanity of this environment.

Here we go!

EOF

rc=0
echo -n "Checking CF_USERNAME... "
if [[ -z ${CF_USERNAME:-} ]]; then
  echo "MISSING!"
  rc=1
else
  echo "${CF_USERNAME}"
fi

echo -n "Checking CF_PASSWORD... "
if [[ -z ${CF_PASSWORD:-} ]]; then
  echo "MISSING!"
  rc=1
else
  echo "(present)"
fi

echo -n "Checking CF_API_URL... "
if [[ -z ${CF_API_URL:-} ]]; then
  echo "MISSING!"
  rc=1
else
  echo "${CF_API_URL}"
fi

echo -n "Checking CF_SKIP_SSL... "
if [[ -z ${CF_SKIP_SSL:-} ]]; then
  echo "no; will verify SSL/TLS certificates"
else
  echo "yes; will NOT verify SSL/TLS certificates"
fi

echo -n "Checking CF_DOMAIN ... "
if [[ -z ${CF_DOMAIN:-} ]]; then
  echo "MISSING!"
  rc=1
else
  echo "${CF_DOMAIN}"
fi

echo -n "Checking CF_ORG... "
if [[ -z ${CF_ORG:-} ]]; then
  echo "MISSING!"
  rc=1
else
  echo "${CF_ORG}"
fi

echo -n "Checking CF_SPACE... "
if [[ -z ${CF_SPACE:-} ]]; then
  echo "MISSING!"
  rc=1
else
  echo "${CF_SPACE}"
fi

n=0
echo -n "Checking if we should run MySQL tests... "
if [[ -z ${MYSQL:-} ]]; then
  echo "no"
else
  echo "yes"
  n=1
fi
echo -n "Checking if we should run Redis tests... "
if [[ -z ${REDIS:-} ]]; then
  echo "no"
else
  echo "yes"
  n=1
fi
echo -n "Checking if we should run MongoDB tests... "
if [[ -z ${MONGO:-} ]]; then
  echo "no"
else
  echo "yes"
  n=1
fi

if [[ ${n} -eq 0 ]]; then
  echo
  echo "No test suites have been specified!"
  rc=1
fi

if [[ ${rc} -ne 0 ]]; then
  echo
  echo "Pre-flight checks FAILED."
  echo "Please correct these errors and try again."
  exit 1
fi

CFOPTS=
CURLOPTS=
if [[ -n ${CF_SKIP_SSL} ]]; then
	CFOPTS="--skip-ssl-validation"
	CURLOPTS="-k"
fi

set -e
cf api ${CFOPTS} ${CF_API_URL}
cf auth ${CF_USERNAME} ${CF_PASSWORD}
cf target -o ${CF_ORG} -s ${CF_SPACE}
cf delete -f cloudvet &>/dev/null || true
cf push -b binary_buildpack -d ${CF_DOMAIN} --no-start -c ./cloudvet cloudvet
echo ; echo ; echo

cf delete-service -f cloudvet-redis &>/dev/null || true
cf delete-service -f cloudvet-mysql &>/dev/null || true
cf delete-service -f cloudvet-mongo &>/dev/null || true

cf_wait_for cloudvet-redis &>/dev/null || true
cf_wait_for cloudvet-mysql &>/dev/null || true
cf_wait_for cloudvet-mongo &>/dev/null || true

if [[ -n ${REDIS:-} ]]; then
  (set -x ; cf create-service ${REDIS} cloudvet-redis)
fi
if [[ -n ${MYSQL:-} ]]; then
  (set -x ; cf create-service ${MYSQL} cloudvet-mysql)
fi
if [[ -n ${MONGO:-} ]]; then
  (set -x ; cf create-service ${MONGO} cloudvet-mongo)
fi

if [[ -n ${REDIS:-} ]]; then
  cf_wait_for cloudvet-redis
  (set -x ; cf bind-service cloudvet cloudvet-redis)
fi
if [[ -n ${MYSQL:-} ]]; then
   cf_wait_for cloudvet-mysql
  (set -x ; cf bind-service cloudvet cloudvet-mysql)
fi
if [[ -n ${MONGO:-} ]]; then
  cf_wait_for cloudvet-mongo
  (set -x ; cf bind-service cloudvet cloudvet-mongo)
fi

echo ; echo ; echo
cf start cloudvet
echo ; echo ; echo
curl -Ls ${CURLOPTS} --fail https://cloudvet.${CF_DOMAIN}/ping
if [[ -n ${REDIS:-} ]]; then
  curl -Ls ${CURLOPTS} --fail https://cloudvet.${CF_DOMAIN}/redis
fi
if [[ -n ${MYSQL:-} ]]; then
  curl -Ls ${CURLOPTS} --fail https://cloudvet.${CF_DOMAIN}/mysql
fi
if [[ -n ${MONGO:-} ]]; then
  curl -Ls ${CURLOPTS} --fail https://cloudvet.${CF_DOMAIN}/mongo
fi

cf delete -f cloudvet
cf delete-route -f -n cloudvet ${CF_DOMAIN} &>/dev/null || true
cf delete-service -f cloudvet-redis &>/dev/null || true
cf delete-service -f cloudvet-mysql &>/dev/null || true
cf delete-service -f cloudvet-mongo &>/dev/null || true
exit 0
