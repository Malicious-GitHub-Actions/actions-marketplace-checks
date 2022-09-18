# GitHub Actions Marketplace information

Goal: Run checks on actions in the marketplace: I have a private datasource of all actions found in the public marketplace that is created and used by my [Twitter bot](https://twitter.com/githubactions) setup, that tweets out updated and new actions. 

Information being loaded (see the [report workflow](.github/workflows/report.yml)) for all actions in that dataset:

|Information|Description|
|---|---|
|Type of Action|Docker, Node or Composite action|
|Declaration of the Action|action.yml, action.yaml, Dockerfile|
|Docker image setup|Dockerfile in repo or remote image url (e.g. Docker hub, GitHub Container Registry, etc.|
|Security alerts|Fork the Action and enabling Dependabot (works only for Node actions), then read back the security alerts|
