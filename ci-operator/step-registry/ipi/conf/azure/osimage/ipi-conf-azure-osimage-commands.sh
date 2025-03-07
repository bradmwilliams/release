#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# release-controller always expose RELEASE_IMAGE_LATEST when job configuraiton defines release:latest image
echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST:-}"
# RELEASE_IMAGE_LATEST_FROM_BUILD_FARM is pointed to the same image as RELEASE_IMAGE_LATEST, 
# but for some ci jobs triggerred by remote api, RELEASE_IMAGE_LATEST might be overridden with 
# user specified image pullspec, to avoid auth error when accessing it, always use build farm 
# registry pullspec.
echo "RELEASE_IMAGE_LATEST_FROM_BUILD_FARM: ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"
# seem like release-controller does not expose RELEASE_IMAGE_INITIAL, even job configuraiton defines 
# release:initial image, once that, use 'oc get istag release:inital' to workaround it.
echo "RELEASE_IMAGE_INITIAL: ${RELEASE_IMAGE_INITIAL:-}"
if [[ -n ${RELEASE_IMAGE_INITIAL:-} ]]; then
    tmp_release_image_initial=${RELEASE_IMAGE_INITIAL}
    echo "Getting inital release image from RELEASE_IMAGE_INITIAL..."
elif oc get istag "release:initial" -n ${NAMESPACE} &>/dev/null; then
    tmp_release_image_initial=$(oc -n ${NAMESPACE} get istag "release:initial" -o jsonpath='{.tag.from.name}')
    echo "Getting inital release image from build farm imagestream: ${tmp_release_image_initial}"
fi
# For some ci upgrade job (stable N -> nightly N+1), RELEASE_IMAGE_INITIAL and 
# RELEASE_IMAGE_LATEST are pointed to different imgaes, RELEASE_IMAGE_INITIAL has 
# higher priority than RELEASE_IMAGE_LATEST
TESTING_RELEASE_IMAGE=""
if [[ -n ${tmp_release_image_initial:-} ]]; then
    TESTING_RELEASE_IMAGE=${tmp_release_image_initial}
else
    TESTING_RELEASE_IMAGE=${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}
fi
echo "TESTING_RELEASE_IMAGE: ${TESTING_RELEASE_IMAGE}"

dir=$(mktemp -d)
pushd "${dir}"
cp ${CLUSTER_PROFILE_DIR}/pull-secret pull-secret
# After cluster is set up, ci-operator make KUBECONFIG pointing to the installed cluster,
# to make "oc registry login" interact with the build farm, set KUBECONFIG to empty,
# so that the credentials of the build farm registry can be saved in docker client config file.
KUBECONFIG="" oc registry login --to pull-secret
ocp_version=$(oc adm release info --registry-config pull-secret ${TESTING_RELEASE_IMAGE} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
echo "OCP Version: $ocp_version"
rm pull-secret
popd

CONFIG="${SHARED_DIR}/install-config.yaml"
ocp_minor_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $2}' )

# az should already be there
command -v az

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

# log in with az
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription ${AZURE_AUTH_SUBSCRIPTION_ID}

#Get imageinfo list
if [[ "${OS_IMAGE_URN}" != "" ]]; then
    image=${OS_IMAGE_URN}
    IFS=':' read -ra imageInfo <<< "${image}"
else
    # random select image from azure marketplace with sepcified version
    # Generation: gen1 or gen2
    offer="rh-ocp-worker"
    publisher="RedHat"
    images=$(az vm image list --all --offer ${offer} -o tsv --query "[?publisher=='${publisher}'] | [?version=='${OS_IMAGE_VERSION}'].urn")
    mapfile -t marketImages <<< "${images}"
    echo "choice market-place image from:" "${marketImages[@]}"
    imageTotal=${#marketImages[@]}
    echo "Image total: ${imageTotal} "
    if [ ${imageTotal} -lt 1 ] ; then
        echo "Fail to find the market-place image under the ${AZURE_AUTH_LOCATION}"
        exit 1
    fi
    selected_image_idx=$((RANDOM % ${imageTotal}))
    image=${marketImages[selected_image_idx]}
    echo "$(date -u --rfc-3339=seconds) - Selected image ${image}"
    IFS=':' read -ra imageInfo <<< "${image}"
fi
echo "imageInfo: " "${imageInfo[@]}"

# image plan is case-sensitive, make sure that publisher/offer/sku keep the same as plan
if [[ "${OS_IMAGE_PLAN}" == "WithPurchasePlan" ]] || [[ "${OS_IMAGE_PLAN}" == "" ]]; then
    imageInfo[0]=$(az vm image show --urn ${image} --query 'plan.publisher' -otsv)
    imageInfo[1]=$(az vm image show --urn ${image} --query 'plan.product' -otsv)
    imageInfo[2]=$(az vm image show --urn ${image} --query 'plan.name' -otsv)
fi

#set plan for os image, default value is WithPurchasePlan
osimage_plan=""
if [[ "${OS_IMAGE_PLAN}" != "" ]]; then
    osimage_plan="plan: ${OS_IMAGE_PLAN}"
fi

# create/apply a patch to set osImage for compute
PATCH="/tmp/install-config-workers-marketimage.yaml.patch"
cat > "${PATCH}" << EOF
compute:
- platform:
    azure:
      osImage:
        publisher: ${imageInfo[0]}
        offer: ${imageInfo[1]}
        sku: ${imageInfo[2]}
        version: ${imageInfo[3]}
        ${osimage_plan}
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"
#save worker image urn to ${SHARED_DIR}
echo "${image}" > "${SHARED_DIR}"/azure_marketplace_image_urn_worker

if [[ ${ocp_minor_version} -ge 14 ]]; then
  # create/apply a patch to set osImage for control plane instances
  PATCH_MASTER="${SHARED_DIR}/install-config-master-marketimage.yaml.patch"
  cat > "${PATCH_MASTER}" << EOF
controlPlane:
  platform:
    azure:
      osImage:
        publisher: ${imageInfo[0]}
        offer: ${imageInfo[1]}
        sku: ${imageInfo[2]}
        version: ${imageInfo[3]}
        ${osimage_plan}
EOF
  yq-go m -x -i "${CONFIG}" "${PATCH_MASTER}"

  #save master image urn to ${SHARED_DIR}
  echo "${image}" > "${SHARED_DIR}"/azure_marketplace_image_urn_master
fi
