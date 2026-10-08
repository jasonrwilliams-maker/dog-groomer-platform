"""Passkeys for opening Admin (section 33).

The signature checks are the WebAuthn library's (py_webauthn), never ours:
this module only builds its options and hands it what the browser sent back.
Who a passkey opens Admin for, and who may add one, is the database's call.

A passkey belongs to a website's name. Here that is "localhost", reached at
http://localhost:3000. Put online, set PASSKEY_RP_ID to the site's domain and
PASSKEY_ORIGINS to its https address; passkeys made for localhost will not
work there (that is the point of them).
"""
from __future__ import annotations

import hashlib
import json
import os
import secrets
from uuid import UUID

from webauthn import (
    generate_authentication_options,
    generate_registration_options,
    options_to_json,
    verify_authentication_response,
    verify_registration_response,
)
from webauthn.helpers import base64url_to_bytes
from webauthn.helpers.structs import (
    AuthenticatorSelectionCriteria,
    PublicKeyCredentialDescriptor,
    ResidentKeyRequirement,
    UserVerificationRequirement,
)

RP_NAME = "Paws & Polish Admin"


def rp_id() -> str:
    return os.environ.get("PASSKEY_RP_ID", "localhost")


def origins() -> list[str]:
    return os.environ.get("PASSKEY_ORIGINS", "http://localhost:3000").split(",")


def new_token() -> tuple[str, str]:
    """A session token for the browser, and the hash the database keeps."""
    token = secrets.token_urlsafe(32)
    return token, token_hash(token)


def token_hash(token: str | None) -> str | None:
    return hashlib.sha256(token.encode()).hexdigest() if token else None


def registration_options(manager_id: UUID, email: str, name: str, existing: list[bytes]) -> tuple[dict, bytes]:
    """Options for adding a passkey. User verification is required: the
    fingerprint, face or device PIN, not just a tap."""
    opts = generate_registration_options(
        rp_id=rp_id(), rp_name=RP_NAME,
        user_id=manager_id.bytes, user_name=email, user_display_name=name,
        authenticator_selection=AuthenticatorSelectionCriteria(
            resident_key=ResidentKeyRequirement.PREFERRED,
            user_verification=UserVerificationRequirement.REQUIRED),
        exclude_credentials=[PublicKeyCredentialDescriptor(id=c) for c in existing],
    )
    return json.loads(options_to_json(opts)), opts.challenge


def check_registration(credential: dict, challenge: bytes):
    """The new passkey's id, public key and counter, once its proof checks out."""
    return verify_registration_response(
        credential=credential, expected_challenge=challenge,
        expected_rp_id=rp_id(), expected_origin=origins(), require_user_verification=True)


def opening_options(keys: list[bytes]) -> tuple[dict, bytes]:
    """Options for opening Admin with one of this manager's passkeys."""
    opts = generate_authentication_options(
        rp_id=rp_id(),
        allow_credentials=[PublicKeyCredentialDescriptor(id=c) for c in keys],
        user_verification=UserVerificationRequirement.REQUIRED,
    )
    return json.loads(options_to_json(opts)), opts.challenge


def credential_id(credential: dict) -> bytes:
    return base64url_to_bytes(credential["rawId"])


def check_opening(credential: dict, challenge: bytes, public_key: bytes, sign_count: int):
    """The passkey's new counter, once its signature over the challenge checks out.

    The fingerprint is asked for, but its flag is not insisted on here: on a
    real Windows laptop the answer came back signed by the right key without
    it (Windows Hello had just verified, or a password manager answered for
    it), and refusing that locked a manager out of her own Admin. Adding a
    passkey does insist on it, so every key on file was made by its owner
    with their fingerprint; opening needs that key's signature over a
    challenge used once."""
    return verify_authentication_response(
        credential=credential, expected_challenge=challenge,
        expected_rp_id=rp_id(), expected_origin=origins(),
        credential_public_key=public_key, credential_current_sign_count=sign_count,
        require_user_verification=False)
