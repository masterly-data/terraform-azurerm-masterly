variable "license_token" {
  type        = string
  default     = null
  sensitive   = true
  description = "The licence JWT to check (the root module's license_token). Null = no licence, nothing to check. Only its JOSE header is read; the payload and signature are never decoded here, and the token is not verified — the application does that at startup."
}

variable "api_image" {
  type        = string
  description = "The pinned api image (registry/repository:tag, registry/repository:tag@sha256:<digest> or registry/repository@sha256:<digest>). A reference with a tag is compared by its tag with the api images the manifest records, so an image mirrored into your own registry under the same tag is recognised; a digest-only reference is compared by its digest with the api digests the manifest records."
}

variable "manifest" {
  type        = any
  description = "The decoded release manifest (MANIFEST.json, docs/release-manifest.md): the api image, api digest and api_claims_version of every recorded module release."
}
