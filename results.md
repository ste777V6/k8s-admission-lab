## First run 

Three of the four cases passed, and the fourth failed on a size limit, not on security. Kyverno’s logs show each check separately:

Case	Result	What Kyverno logged
unsigned (busybox)	✅ denied	no matching signatures
wrong-identity	✅ denied	validly signed, but not by your workflow
unsigned-sandbox	✅ admitted	namespace not enforced
signed	❌ denied	① signature verified ✅ ② SLSA provenance verified with all 4 conditions ✅ ③ SBOM: context size limit exceeded: 2265002 bytes exceeds limit of 2097152 bytes

So the core of the project already works on a real cluster. Your image’s signature and provenance were accepted, including the repo, main, and GitHub-hosted runner conditions, and the wrong identity was rejected.

Why it failed: Kyverno loads each attestation into memory to evaluate the policy, and caps that at 2 MiB by default (maxContextSize). The SBOM of your small Python image is already 2.2 MB. The policy failed closed, so it denied rather than letting the pod through, which is the correct behaviour for a resource limit.

The fix: setup.sh now installs Kyverno with config.maxContextSize=8Mi. I checked the setting in Kyverno 1.19.2’s Helm chart and in the code that reads it, which accepts values like 8Mi. The setup log will print the value applied, so the next run proves the setting took effect. The README now documents this run and the trade-off: a bigger limit means more memory per request, and the limit should be sized from your largest SBOM.

To re-run:

powershell
cd "C:\Users\stefa\VS Projects"
Expand-Archive -Path "$HOME\Downloads\k8s-admission-lab.zip" -DestinationPath . -Force
cd k8s-admission-lab
git add .
git commit -m "Raise Kyverno maxContextSize to 8Mi: SBOM attestation is 2.2 MB"
git push

The push starts e2e again. Expect four PASS lines, with signed showing image after admission: ghcr.io/ste777v6/supply-chain@sha256:6dbfed67… (the digest Kyverno verified in this run), and Kyverno config maxContextSize: 8Mi in the setup step.

This run is good interview material as it is: the policy rejected a validly signed image from the wrong identity, and when a resource limit was hit, it failed closed instead of failing open. Send me the next log.

##Second run

All four cases pass on a real cluster. Project 3 works end to end, and the policy is proven both ways:

Case	    Result	    What it proves

signed	    ✅ admitted, pinned to @sha256:6dbfed67…	Signature from          your    workflow on main, SLSA provenance (repo, ref,                       GitHub-hosted runner) and SBOM attestation all verified at admission
unsigned	✅ denied	    No signature at all → rejected
wrong-identity	✅ denied	Validly signed by someone else → still                          rejected: who signed matters
unsigned-sandbox	✅ admitted	Enforcement is scoped to labelled namespaces

Kyverno rewrote the image to …:latest@sha256:6dbfed67…. With both a tag and a digest present, the container runtime pulls by the digest, so the pod runs exactly the image that was verified, even if :latest is moved later. It’s the same digest Kyverno verified in run 1, which ties the result to the image your pipeline built.