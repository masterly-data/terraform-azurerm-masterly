# acs-email

Azure Communication Services email — the self-hosted, customer-owned email provider for Masterly
notifications (ADR 0040). Off by default; air-gapped installs use SMTP instead.

## What it creates

- `azurerm_communication_service` — the Communication Service the app's SDK connects to.
- `azurerm_email_communication_service` + an **Azure-managed domain** (`*.azurecomm.net`,
  auto-verified — no DNS records to add).
- The domain ↔ service association, so the service may send from that domain.

The **role assignment** ("Communication and Email Service Owner" for the apps managed identity) is
granted at the **root** (`email.tf`), not in this module, because the apps identity lives there.

## Enabling

In your deployment (e.g. `deployments/<install>/main.tf`), set on the root module call:

```hcl
email_acs_enabled       = true
email_acs_data_location = "Europe" # must match the install geo (ADR 0003)
```

Then `terraform apply`.

## Wiring into the app

After apply, read the outputs and enter them in the product under
**Notifications → Integrations → Email**, provider **Azure Communication Services**:

```bash
terraform output acs_email_endpoint        # -> endpoint
terraform output acs_email_sender_address  # -> from address
```

Auth is the install's managed identity (`DefaultAzureCredential`); `AZURE_CLIENT_ID` must point at
the apps UAMI — the same identity used for the Service Bus binding — so **no secret** is stored.

## Notes

- **Custom domain** (your own sender domain) is `domain_management = "CustomerManaged"` plus DNS
  verification (TXT/SPF/DKIM) — a documented follow-up.
- **Data residency:** `data_location` pins ACS data at rest to a geo; keep it aligned with the
  install's region (ADR 0003).
