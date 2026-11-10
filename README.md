# Quick Dashboard Share

Share **one** Amazon Quick / QuickSight dashboard with people who do **not** have
SSO (no Microsoft/Entra, no QuickSight login). Viewers open a public HTTPS link,
type a password, and see the dashboard embedded as one existing registered user.

- **No extra seat / session cost** - everyone views as one already-paid registered user.
- **No SSO, no identity provider** - a password is the only gate.
- **Locked to a single dashboard** - viewers cannot reach the console, analyses, or datasets.
- **Compliant, not a bypass** - the Lambda Function URL uses `AWS_IAM` auth; CloudFront
  signs every request with SigV4 via Origin Access Control (OAC). Nothing is anonymous.

## Architecture

```
viewer (browser) --HTTPS--> CloudFront (OAC, signs SigV4)
                               |
                               v
                     Lambda Function URL (AuthType AWS_IAM)
                       - serves the gate page + the embedding SDK
                       - checks the password, sets a signed cookie
                       - mints GenerateEmbedUrlForRegisteredUser (one user)
```

## Prerequisites

- AWS CLI v2 configured with a profile that can create IAM roles, Lambda, and CloudFront
  in the account that owns the dashboard.
- PowerShell 7+ (`pwsh`) - cross-platform (Windows, macOS, Linux).
- A Quick/QuickSight **registered user** (author/admin) ARN to embed as, and the
  **dashboard id** to share. That user must have view permission on the dashboard.
- The account must allow public CloudFront distributions (most do).

## Deploy (two steps)

1. Fill in your values:
   ```bash
   cp config.example.json config.json
   # edit config.json: accountId, dashboardId, userArn (region/profile if not defaults)
   ```
2. Run:
   ```bash
   pwsh ./deploy/deploy.ps1
   ```

It prints a **SHARE URL** and a generated **PASSWORD** (shown only in your terminal).
Send the URL and the password to viewers over **two different channels**.

CloudFront takes 3-10 minutes to deploy the first time; the script waits for it.

## Manage

| Action | Command |
|---|---|
| Rotate the password (invalidates open sessions) | `pwsh ./deploy/reset_password.ps1` |
| Shorten the session, e.g. 60 min | `pwsh ./deploy/reset_password.ps1 -SessionMinutes 60` |
| Remove everything | `pwsh ./deploy/teardown.ps1` |

## Security notes

- The link is public; the **password is the only gate**. Use the generated 20-char
  password, rotate it when someone leaves, and never send the link and password together.
- Every viewer is seen by Quick as the one embed user, so there is **no per-viewer audit**.
  In exchange the embed is locked to exactly one dashboard.
- The Lambda holds AWS permissions. Run it only in an account you control; never commit
  `config.json`, `.deploy-state.json`, or any generated password (all are gitignored).
- Cross-account: if the dashboard is in a different account, set `mintRoleArn`
  (a role in that account this Lambda may assume) and `mintExternalId` in `config.json`.

## Cost

At low usage this is effectively **$0/month**: CloudFront and Lambda free tiers cover a
handful of viewers, and embedding as an existing registered user adds no QuickSight cost.
The only variable is CloudFront data transfer if usage grows.

## For an AI agent deploying this repo

If a user hands you this repository and asks you to deploy it:

1. Confirm the AWS profile and region. Discover candidates if unknown:
   - dashboards: `aws quicksight list-dashboards --aws-account-id <ACCT> --region <REGION>`
   - registered users: `aws quicksight list-users --aws-account-id <ACCT> --namespace default --region <REGION>`
2. Ask the user which dashboard to share and which registered user to embed as. Do not guess.
3. Write `config.json` from `config.example.json` with their values. Never invent an
   account id, dashboard id, or user ARN.
4. Run `pwsh ./deploy/deploy.ps1`.
5. Return the **SHARE URL** to the user. Treat the **PASSWORD** as a secret: deliver it
   out of band and do **not** paste it into a shared chat transcript or log.
6. To remove, run `pwsh ./deploy/teardown.ps1`.

## License

MIT - see [LICENSE](LICENSE). The Amazon QuickSight Embedding SDK is downloaded at
deploy time and is licensed separately; see [NOTICE](NOTICE).
