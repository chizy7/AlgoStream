#!/usr/bin/env bash
# Promote the inactive slot: stand it up, gate on health, flip the Service, scale the old one down.
#
# VERIFICATION STATUS: exercised on a single-node kind cluster — a full promotion (scale up, health
# gate, flip, drain, scale down) and a rollback, with the Service serving 200 throughout. The
# rollback path was broken until that run: it flipped the selector to a slot the previous promotion
# had scaled to zero, leaving the Service with no endpoints. See the --rollback branch below.
#
# Not validated: multi-node. The audit PVC is ReadWriteOnce, so a flip across nodes cannot mount it
# from both slots at once; on one node the question never arises.
#
#   scripts/blue-green.sh [--namespace NS] [--image IMAGE] [--timeout SECONDS]
#   scripts/blue-green.sh --rollback     flip straight back to the other slot
#
# The health gate is the point. Flipping a Service selector is instant and unconditional, so without
# a gate a broken build takes traffic the moment it is applied. This waits for the rollout, then
# polls the new slot's own Service until /api/health answers 200 — the readiness probe already gates
# endpoint membership, but checking again here means the script fails rather than the users.

set -euo pipefail

NAMESPACE="default"
IMAGE=""
TIMEOUT=180
ROLLBACK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --image)     IMAGE="$2";     shift 2 ;;
    --timeout)   TIMEOUT="$2";   shift 2 ;;
    --rollback)  ROLLBACK=1;     shift ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

k() { kubectl --namespace "$NAMESPACE" "$@"; }

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 2; }

ACTIVE=$(k get service algostream -o jsonpath='{.spec.selector.slot}')
[[ -n "$ACTIVE" ]] || { echo "could not read the active slot from the algostream Service" >&2; exit 1; }

if [[ "$ACTIVE" == "blue" ]]; then TARGET="green"; else TARGET="blue"; fi

echo "active: $ACTIVE  ->  target: $TARGET"

if [[ "$ROLLBACK" == "1" ]]; then
  # Deliberately no *health gate*: a rollback is what you reach for when things are already wrong,
  # and making it conditional on the very health check that is failing would be exactly backwards.
  #
  # It must still scale the target up first. A completed promotion scales the old slot to zero (see
  # the end of this script), so the slot being rolled back to has no pods at all — flipping the
  # selector straight to it pointed the Service at zero endpoints and took the service completely
  # down. Observed on a kind cluster: `kubectl get endpointslice` returned null and requests failed
  # to connect. A rollback that causes an outage is worse than no rollback.
  echo "rolling back to $TARGET (no health gate; scaling it up first)"
  k scale "deployment/algostream-$TARGET" --replicas=1

  # Bounded wait for a ready endpoint, then flip regardless. Waiting makes the common case
  # seamless; flipping anyway on timeout keeps the rollback unconditional, which is the whole point
  # of the command.
  echo "waiting up to ${TIMEOUT}s for $TARGET to have a ready pod"
  if k rollout status "deployment/algostream-$TARGET" --timeout="${TIMEOUT}s"; then
    echo "$TARGET is ready"
  else
    echo "WARNING: $TARGET did not become ready in ${TIMEOUT}s — flipping anyway, as requested." >&2
    echo "         The Service may have no endpoints until it recovers." >&2
  fi

  k patch service algostream -p "{\"spec\":{\"selector\":{\"app\":\"algostream\",\"slot\":\"$TARGET\"}}}"
  echo "traffic is now on $TARGET"
  # The failed slot is left running on purpose: it is the thing you want to inspect. Scale it down
  # with `kubectl scale deployment/algostream-$ACTIVE --replicas=0` once you are done.
  echo "$ACTIVE is still running for diagnosis; scale it down when finished"
  exit 0
fi

if [[ -n "$IMAGE" ]]; then
  echo "setting image on algostream-$TARGET to $IMAGE"
  k set image "deployment/algostream-$TARGET" "algostream=$IMAGE"
fi

echo "scaling algostream-$TARGET up"
k scale "deployment/algostream-$TARGET" --replicas=1

echo "waiting for the rollout (timeout ${TIMEOUT}s)"
k rollout status "deployment/algostream-$TARGET" --timeout="${TIMEOUT}s"

echo "health-gating $TARGET before it takes any traffic"
deadline=$(( SECONDS + TIMEOUT ))
healthy=0
while (( SECONDS < deadline )); do
  # Run the probe from inside the cluster, against the target's own Service, so this works without
  # an ingress and without port-forwarding.
  if k run "bg-probe-$$" --rm -i --restart=Never --image=curlimages/curl:8.8.0 --quiet -- \
       curl -fsS --max-time 5 "http://algostream-$TARGET:8080/api/health" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 5
done

if [[ "$healthy" != "1" ]]; then
  echo "FAILED: $TARGET never became healthy — leaving traffic on $ACTIVE" >&2
  echo "scaling $TARGET back down" >&2
  k scale "deployment/algostream-$TARGET" --replicas=0
  exit 1
fi

echo "flipping the Service to $TARGET"
k patch service algostream -p "{\"spec\":{\"selector\":{\"app\":\"algostream\",\"slot\":\"$TARGET\"}}}"

# Deliberately after the flip, and deliberately not immediate: connections already established
# against the old slot — including SSE streams, which are long-lived by nature — keep their pods
# alive until they drain.
echo "waiting 30s for in-flight connections to drain from $ACTIVE"
sleep 30

echo "scaling algostream-$ACTIVE down"
k scale "deployment/algostream-$ACTIVE" --replicas=0

echo "done — traffic is on $TARGET; roll back with: $0 --namespace $NAMESPACE --rollback"
