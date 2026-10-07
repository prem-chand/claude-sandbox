# Virtual keys need a Postgres database, so this hook gives the claude
# container a key that can only reach the model routes. The master key keeps
# full access for the host.
import os
import secrets

from fastapi import HTTPException, Request
from litellm.proxy._types import LitellmUserRoles, UserAPIKeyAuth

CLIENT_ROUTES = frozenset({"/v1/messages", "/v1/messages/count_tokens", "/v1/models"})


def _matches(api_key: str, env_var: str) -> bool:
    return secrets.compare_digest(api_key.encode(), os.environ[env_var].encode())


async def user_api_key_auth(request: Request, api_key: str) -> UserAPIKeyAuth:
    if _matches(api_key, "LITELLM_MASTER_KEY"):
        return UserAPIKeyAuth(api_key=api_key, user_role=LitellmUserRoles.PROXY_ADMIN)
    if _matches(api_key, "LITELLM_CLIENT_KEY"):
        if request.url.path in CLIENT_ROUTES:
            return UserAPIKeyAuth(api_key=api_key, user_role=LitellmUserRoles.INTERNAL_USER)
        raise HTTPException(status_code=403, detail=f"Client key cannot call {request.url.path}")
    raise HTTPException(status_code=401, detail="Invalid proxy key")
