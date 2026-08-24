# Submissions checklist — IBM Guestbook final project

10 deliverable files, no extensions, as required by the grader.

## Done (prepared locally, no real terminal output needed)

- [x] `Dockerfile` — final completed `v1/guestbook/Dockerfile` (two-stage build, 15 instructions).
- [x] `app` — verbatim default `v1/guestbook/public/index.html` (title: "Lavanya's Guestbook - v1", h1: "Guestbook - v1"), copied before any edits.
- [x] `up-app` — verbatim `v1/guestbook/public/index.html` after the v2 edit (title and h1 both "Guestbook - v2").

## Still needed — paste real terminal output from the IBM Cloud IDE (Theia)

Run these in order inside your IBM Cloud Theia terminal, then paste each output back verbatim.

- [ ] `crimages` — after building & pushing the v1 image:
  ```
  docker build . -t us.icr.io/<your_namespace>/guestbook:v1
  docker push us.icr.io/<your_namespace>/guestbook:v1
  ibmcloud cr images
  ```
- [ ] `hpa` — right after creating the HPA (should show 0 replicas / no load yet):
  ```
  kubectl autoscale deployment guestbook --cpu-percent=5 --min=1 --max=10
  kubectl get hpa guestbook
  ```
- [ ] `hpa2` — after running the load generator, watching replicas scale up:
  ```
  kubectl get hpa guestbook --watch
  ```
- [ ] `upguestbook` — full build+push output for the v2 image update (same tag, `:v1`), including the final digest line:
  ```
  docker build . -t us.icr.io/<your_namespace>/guestbook:v1
  docker push us.icr.io/<your_namespace>/guestbook:v1
  ```
- [ ] `deployment` — after editing deployment.yml CPU limits/requests to 5m/2m:
  ```
  kubectl apply -f deployment.yml
  ```
- [ ] `rev` — both commands, labeled:
  ```
  kubectl rollout history deployment/guestbook
  kubectl rollout history deployments guestbook --revision=2
  ```
- [ ] `rs` — after rolling back to revision 1:
  ```
  kubectl rollout undo deployment/guestbook --to-revision=1
  kubectl get rs
  ```

Each pending file currently contains a bracketed placeholder describing exactly what to run and when. Do not fill these in with anything other than real command output — paste it back here (or hand it to Claude Code) and it will be inserted verbatim, with no reformatting or correction.
