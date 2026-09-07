"""비밀번호 해싱 / JWT 테스트."""

from __future__ import annotations

import time
from datetime import timedelta

import pytest

from app.core.errors import InvalidTokenError, TokenExpiredError
from app.core.security import (
    _encode,
    create_access_token,
    create_refresh_token,
    decode_token,
    generate_opaque_token,
    hash_password,
    verify_password,
)


class TestPasswordHashing:
    def test_hash_and_verify(self) -> None:
        hashed = hash_password("correct-horse-battery")
        assert verify_password("correct-horse-battery", hashed)

    def test_wrong_password_rejected(self) -> None:
        hashed = hash_password("correct-horse-battery")
        assert not verify_password("wrong-password", hashed)

    def test_hash_is_salted(self) -> None:
        assert hash_password("same") != hash_password("same")

    def test_uses_argon2id(self) -> None:
        assert hash_password("x").startswith("$argon2id$")

    def test_none_hash_returns_false_without_crashing(self) -> None:
        """존재하지 않는 계정 로그인 시 타이밍을 맞추기 위한 경로."""
        assert not verify_password("anything", None)

    def test_long_password_is_not_truncated(self) -> None:
        """bcrypt 는 72바이트에서 잘리지만 Argon2 는 그렇지 않아야 한다."""
        base = "a" * 80
        hashed = hash_password(base + "TAIL1")
        assert not verify_password(base + "TAIL2", hashed)

    def test_unicode_password(self) -> None:
        hashed = hash_password("비밀번호입니다🔐")
        assert verify_password("비밀번호입니다🔐", hashed)


class TestTokens:
    def test_access_token_roundtrip(self) -> None:
        token, _ = create_access_token("user-123")
        payload = decode_token(token, expected_type="access")

        assert payload["sub"] == "user-123"
        assert payload["typ"] == "access"
        assert "jti" in payload

    def test_refresh_token_roundtrip(self) -> None:
        token, jti, _ = create_refresh_token("user-123")
        payload = decode_token(token, expected_type="refresh")

        assert payload["sub"] == "user-123"
        assert payload["jti"] == jti

    def test_refresh_token_rejected_as_access_token(self) -> None:
        """이 검사가 없으면 리프레시 토큰으로 API 를 호출할 수 있게 된다."""
        token, _, _ = create_refresh_token("user-123")
        with pytest.raises(InvalidTokenError):
            decode_token(token, expected_type="access")

    def test_access_token_rejected_as_refresh_token(self) -> None:
        token, _ = create_access_token("user-123")
        with pytest.raises(InvalidTokenError):
            decode_token(token, expected_type="refresh")

    def test_expired_token_raises(self) -> None:
        token, _, _ = _encode("user-123", "access", timedelta(seconds=-10))
        with pytest.raises(TokenExpiredError):
            decode_token(token, expected_type="access")

    def test_tampered_token_raises(self) -> None:
        token, _ = create_access_token("user-123")
        tampered = token[:-3] + ("aaa" if not token.endswith("aaa") else "bbb")
        with pytest.raises(InvalidTokenError):
            decode_token(tampered, expected_type="access")

    def test_garbage_token_raises(self) -> None:
        with pytest.raises(InvalidTokenError):
            decode_token("not-a-jwt", expected_type="access")

    def test_each_token_has_unique_jti(self) -> None:
        _, first, _ = create_refresh_token("user-123")
        _, second, _ = create_refresh_token("user-123")
        assert first != second

    def test_issued_at_is_recent(self) -> None:
        token, _ = create_access_token("user-123")
        payload = decode_token(token, expected_type="access")
        assert abs(int(payload["iat"]) - int(time.time())) < 5


class TestOpaqueTokens:
    def test_length_and_uniqueness(self) -> None:
        tokens = {generate_opaque_token() for _ in range(100)}
        assert len(tokens) == 100
        assert all(len(t) >= 32 for t in tokens)

    def test_url_safe(self) -> None:
        token = generate_opaque_token()
        assert all(c.isalnum() or c in "-_" for c in token)
