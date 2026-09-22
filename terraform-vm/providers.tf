terraform {
  required_version = ">= 1.12.2"
  required_providers {
    libvirt = {
      source = "dmacvicar/libvirt"
      # Deliberately pinned to the 0.8.x line, NOT floated to latest.
      # v0.9.0 was a ground-up rewrite (different schema entirely: blocks
      # became nested object/list arguments, IP lookup moved to a separate
      # data source, "type" became a required domain argument, etc.) — by
      # the maintainer's own release notes, still had open bugs and sparse
      # docs as of this writing. All of main.tf is written against the
      # legacy 0.8.x schema. Do not bump this to "~> 0.8" (two components)
      # either — that constraint is looser than it looks and will resolve
      # to 0.9.x, which is what caused this pin to exist in the first
      # place. See README "Troubleshooting" for the full story.
      version = "~> 0.8.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}
