# k8s-admission-lab

**Deploy-time enforcement of supply-chain integrity on Kubernetes.** A Kyverno admission
policy only lets a Pod start in an enforced namespace if its image:

1. has a **Sigstore signature** from *your* `supply-chain-lab` pipeline (exact workflow, on `main`,
   via GitHub Actions OIDC, recorded in the public Rekor log),
2. has a **SLSA build provenance** attestation saying it was built from your repo, on `main`, by a
   **GitHub-hosted runner**,
3. has an **SBOM attestation** (SPDX 2.3).

Otherwise the API server **rejects** the Pod. Kyverno also rewrites the image tag to the
verified **digest**, so what runs is exactly what was verified.

Project 3 of the series. Project 1 produces signed, attested images; Project 2 triages their
findings; this project makes sure only those images can run.

| EPAM requirement | Where |
|---|---|
| Provenance and integrity controls | Signature + SLSA provenance + SBOM verified at admission |
| Policy enforcement | `policies/verify-supply-chain.tmpl.yaml`, `failureAction: Enforce`, fail-closed webhook |
| Kubernetes, integrating security controls (nice to have) | kind cluster, Kyverno, namespace-scoped policy, e2e test in CI |

## How the pieces fit

```
supply-chain-lab (Project 1)                     this repo
────────────────────────────                     ─────────
build → scan → push ghcr.io/<you>/…@sha256        kubectl apply pod (image: …:latest)
cosign sign      ─┐                                  │
attest provenance ├─► Sigstore bundles stored  ◄─────┤ Kyverno admission webhook:
attest SBOM      ─┘   as OCI referrers of digest     │  1 resolve tag → digest
                                                     │  2 fetch referrers (bundles)
                                                     │  3 verify cert identity + Rekor
                                                     │  4 check provenance predicate fields
                                                     │  5 require SBOM attestation
                                                     ▼
                                          admit (tag → digest) / DENY
```

**Why `type: SigstoreBundle`.** Cosign v3 signs in the **new Sigstore bundle format by default**,
attached through the OCI referrers API. `actions/attest` with `push-to-registry: true` stores its
attestations the same way. Kyverno's `SigstoreBundle` verifier reads exactly those
referrers (artifact type `application/vnd.dev.sigstore.bundle…`). The older `type: Cosign` mode
looks for the legacy cosign signature layout. Details in *What was verified*.

## Prerequisites

1. **Project 1 is green**: at least one successful `supply-chain` run on `main` (including the
   `verify` job), so `ghcr.io/<you>/supply-chain-lab:latest` exists with signature + attestations.
2. **Make the GHCR package public.** Packages published to your personal account are
   **private by default** and **don't** inherit the repo's visibility. Kyverno (and the kubelet)
   need to read the image and its referrers. Package page → *Package settings* → *Danger Zone* →
   *Change visibility* → Public. ⚠️ GitHub states this **can't be reverted** to private.
   (Alternative if you want it private: a pull secret plus `imageRegistryCredentials` in the
   policy. Not covered here.)
3. Tools: Docker (Docker Desktop with WSL2 on Windows), `kind` v0.33.0, `kubectl`, `helm` v4.
   Run the scripts from WSL or Git Bash as `bash scripts/…` (works even if git lost the executable bit).
   `.gitattributes` keeps `.sh`/YAML files on LF line endings when committed from Windows.

## Run it locally

```bash
# 1. lab.env is preset to ste777V6 / supply-chain (owner in EXACT case)
# 2. cluster + Kyverno 1.19.2 + policy
bash scripts/setup.sh
# 3. the four admission tests
bash scripts/test.sh
# 4. clean up
bash scripts/teardown.sh
```

Expected `scripts/test.sh` output:

```
PASS  signed            expected=admit got=admit
      image after admission: ghcr.io/<you>/supply-chain-lab@sha256:…
PASS  unsigned          expected=deny  got=deny
      reason: … denied the request … busybox …
PASS  wrong-identity    expected=deny  got=deny
      reason: … no matching signatures …
PASS  unsigned-sandbox  expected=admit got=admit
```

| Case | Image | Why |
|---|---|---|
| `signed` | your image, by **tag** | Passes all 3 checks; tag rewritten to digest |
| `unsigned` | `busybox:latest` | No Sigstore bundles at all |
| `wrong-identity` | `ghcr.io/vishal-chdhry/artifact-attestation-example:artifact-attestation` | **Validly** signed and attested with GitHub artifact attestations, but by someone else's workflow. The image is used in Kyverno's own conformance tests. This proves that "signed" isn't enough: *who* signed is what matters |
| `unsigned-sandbox` | `busybox:latest` in `sandbox` | Namespace not labelled `supply-chain: enforced`, so the policy doesn't apply (scoping) |

## Run it in CI (real cluster, no local setup)

Push this repo to GitHub and run the `e2e` workflow (*Actions → e2e → Run workflow*). `lab.env` is
already set to `ste777V6` / `supply-chain`. Repository **variables** `GH_OWNER` / `GH_REPO` are optional
and override it. **This is the easiest way to run it from Windows**: no kind, kubectl or helm needed
locally. It creates a
kind cluster with `helm/kind-action`, installs Kyverno, applies the policy and runs `scripts/test.sh`.
The job fails if any case behaves unexpectedly. It also runs weekly, so an upstream change
(Kyverno, Sigstore, the image) shows up as a red run.

## Try breaking it (interview stories)

- **Built from a branch:** run Project 1's `supply-chain` workflow manually on a non-`main`
  branch (workflow_dispatch). The certificate identity ends in `@refs/heads/<branch>`, so the
  signed pod is **denied**.
- **Tag swap:** push a different image to `:latest` without the pipeline. It has no bundles from
  your identity, so it's **denied**. Already-running pods are unaffected because they were pinned to the digest.
- **Audit first:** switch `failureAction: Enforce` to `Audit` and watch `kubectl get policyreport -A`.
  This is how you roll the policy out to existing clusters without breaking them.

## Design decisions

- **Fail closed** (`webhookConfiguration.failurePolicy: Fail`): if Kyverno can't decide (registry
  or Rekor unreachable, Kyverno down), Pods in enforced namespaces are denied. The trade-off is
  availability. Mitigations: namespace scoping (system namespaces aren't enforced), Kyverno HA
  replicas in production, and Audit mode during rollout.
- **Namespace scoping by label** rather than "everything": enforced where it matters, and
  `kube-system` and Kyverno itself can never be locked out.
- **`imageReferences: ["*"]`**: in an enforced namespace *every* image must come from the
  pipeline, including sidecars and init containers.
- **Identity pinned to an exact workflow + ref**, plus provenance conditions on repository, ref and
  `runner_environment: github-hosted` (rejects builds on self-hosted runners, which are
  harder to trust).
- **`mutateDigest: true`** closes the gap between verification and pull: the Pod runs the
  digest that was verified, not whatever the tag points to later.
- **Autogen** (Kyverno default) extends the Pod rule to Deployments, StatefulSets, Jobs etc., so a
  bad Deployment is rejected at `kubectl apply`, not later at the ReplicaSet.

## First real run (e2e on GitHub Actions, 2026-11-05)

Kind v0.33.0 (Kubernetes v1.37.0), Kyverno v1.19.2. Kyverno's logs showed each check separately:

| Case | Result | Kyverno log |
|---|---|---|
| `unsigned` (busybox) | ✅ denied | `sigstore bundle verification failed: no matching signatures found` |
| `wrong-identity` | ✅ denied | same: valid signatures, but **not from your workflow identity** |
| `unsigned-sandbox` | ✅ admitted | namespace not enforced |
| `signed` | ❌ denied (**config issue, not a security failure**) | ① `image attestors verification succeeded` (signature) ✅ → ② SLSA provenance with all 4 conditions `verification succeeded` ✅ → ③ SBOM: `context size limit exceeded: 2265002 bytes exceeds limit of 2097152 bytes` |

**Root cause:** Kyverno loads each verified attestation into its policy-evaluation context, which is
capped by `config.maxContextSize` (default **2Mi**). The SPDX SBOM of this small Python image is
already ~2.2 MB. **Fix:** `setup.sh` installs Kyverno with `config.maxContextSize=8Mi` (chart value
`config.maxContextSize`, accepts Kubernetes quantities; checked in the chart's `values.yaml` and
`pkg/config/config.go`). The policy still **failed closed** on a resource limit, which is the right
behaviour. Trade-off: a larger cap means more memory per admission request. SBOM size grows with
image size, so in production, size this cap from your largest SBOM, or verify only that the SBOM
attestation exists in a separate, lighter check.

**Run 2:** the `maxContextSize=8Mi` setting took effect (Kyverno log: `maxContextSize configured
bytes=8388608`), but setup stopped earlier on a **startup race**: `helm --wait` returned when the Kyverno
pod was Ready, while its webhook server was still waiting for its TLS certificate
(`secret "kyverno-svc.kyverno.svc.kyverno-tls-pair" not found`). Kyverno validates policies through
its own fail-closed webhook, so `kubectl apply` got `connection refused`. Run 1 passed this step only
by timing. **Fix:** `setup.sh` retries applying the policy every 5 s for up to 2 minutes, then fails
with a clear message. Both paths were tested with a stubbed `kubectl`.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `signed` is denied | `GH_OWNER` case doesn't match your GitHub URL; package still private; Project 1's last run on `main` failed before signing |
| Everything denied, even `sandbox` | You labelled `sandbox`, or the policy match was edited |
| `failed calling webhook "mutate-policy.kyverno.svc" … connection refused` | Kyverno's webhook not serving yet; `setup.sh` retries for 2 minutes |
| `context size limit exceeded` | An attestation (usually the SBOM) is larger than Kyverno's `config.maxContextSize`; raise it in `setup.sh` |
| Timeouts | The cluster can't reach `ghcr.io` / `rekor.sigstore.dev` (proxy or firewall) |
| Logs | `kubectl logs -n kyverno -l app.kubernetes.io/component=admission-controller` |

## What was verified while building this

| Item | How |
|---|---|
| Kyverno **v1.19.2** (Helm chart **3.9.2**) supports `type: SigstoreBundle` (`Cosign` / `SigstoreBundle` / `Notary`) | Kyverno source, `api/kyverno/v1/image_verification_types.go` |
| Bundles are fetched with `remote.Referrers` and filtered by artifact type `application/vnd.dev.sigstore.bundle*`; attestations are filtered by the in-toto `predicateType`; **any** bundle matching the identity satisfies a check | Kyverno source, `pkg/image/verifiers/cpol/cosign/sigstore.go` |
| Policy shape (keyless issuer/subject/Rekor, `type: https://slsa.dev/provenance/v1`, condition on `buildDefinition.buildType`), using a GitHub artifact-attestation image on ghcr.io | Kyverno conformance tests `test/conformance/chainsaw/verify-images/clusterpolicy/standard/sigstore-*` |
| `failureAction` per verifyImages entry; `validationFailureAction`/`failurePolicy` at spec level are **deprecated** → `webhookConfiguration` | Kyverno API source (`spec_types.go`, `common_types.go`) |
| `mutateDigest`, `verifyDigest`, `required` default to true | Kyverno API source (kubebuilder defaults) |
| Rendered policy **validates against Kyverno's v1 CRD schema**, has no unknown fields, and a typo (`SigstoreBundel`) is caught | `jsonschema` against `config/crds/kyverno/kyverno.io_clusterpolicies.yaml` at v1.19.2 |
| cosign v3 `sign` defaults to `--new-bundle-format=true` ("attach a Sigstore bundle using OCI referrers API") | cosign v3.1.4 source `cmd/cosign/cli/options/sign.go` |
| Provenance fields `externalParameters.workflow.{repository,ref,path}`, `internalParameters.github.runner_environment` | GitHub's buildtype spec, `actions/buildtypes` `workflow/v1` |
| GHCR packages are private by default, don't inherit repo visibility, and going public is irreversible | GitHub Packages docs |
| kind v0.33.0 (default node image `kindest/node:v1.37.0`), `helm/kind-action` v1.15.2 (uses kind v0.33.0), `azure/setup-helm` v5.0.1, Helm v4.3.1; admission-controller pod label | Tags and action.yml / chart templates at those versions |
| `scripts/test.sh` logic: PASS on correct decisions, **exit 1** when the policy doesn't enforce | Run against a stub `kubectl` for both scenarios |
| Shell scripts / workflow | `shellcheck` clean · `check-jsonschema` valid · `zizmor` 0 medium/high |

**Now verified on a real cluster:** signature identity, SLSA provenance conditions, the
wrong-identity and unsigned denials, and namespace scoping (see *First real run*).
**Still to verify:** the `signed` case admitted after the `maxContextSize` fix.

~~**Not yet verified:** a real admission decision.~~ There was no Docker or Kubernetes in the
environment where this was written. The `e2e` workflow (or `scripts/setup.sh` + `test.sh`
locally) is the proof. The riskiest assumption is that Kyverno's referrer lookup works against
GHCR for *your* image the way it does in Kyverno's conformance test (also a GHCR image with GitHub
attestations). If `signed` is denied, check the Kyverno logs first.

## Sources

- Kyverno verifyImages: https://kyverno.io/docs/writing-policies/verify-images/
- Kyverno source v1.19.2: https://github.com/kyverno/kyverno/tree/v1.19.2
- GitHub artifact attestations: https://docs.github.com/en/actions/security-guides/using-artifact-attestations-to-establish-provenance-for-builds
- GitHub Actions workflow buildType: https://github.com/actions/buildtypes/tree/main/workflow/v1
- SLSA provenance v1: https://slsa.dev/spec/v1.0/provenance
- Cosign: https://github.com/sigstore/cosign
- GHCR visibility: https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility
- kind: https://kind.sigs.k8s.io/ · helm/kind-action: https://github.com/helm/kind-action
