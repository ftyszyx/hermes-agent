"""FAL_KEY env var normalization (whitespace-only treated as unset)."""


def test_fal_key_whitespace_is_unset(monkeypatch):
    # Whitespace-only FAL_KEY must NOT register as configured, and the managed
    # gateway fallback must be disabled for this assertion to be meaningful.
    monkeypatch.setenv("FAL_KEY", "   ")

    from tools import image_generation_tool

    monkeypatch.setattr(
        image_generation_tool, "_resolve_managed_fal_gateway", lambda: None
    )

    assert image_generation_tool.check_fal_api_key() is False


def test_fal_key_valid(monkeypatch):
    monkeypatch.setenv("FAL_KEY", "sk-test")

    from tools import image_generation_tool

    monkeypatch.setattr(
        image_generation_tool, "_resolve_managed_fal_gateway", lambda: None
    )

    assert image_generation_tool.check_fal_api_key() is True


def test_fal_key_empty_is_unset(monkeypatch):
    monkeypatch.setenv("FAL_KEY", "")

    from tools import image_generation_tool

    monkeypatch.setattr(
        image_generation_tool, "_resolve_managed_fal_gateway", lambda: None
    )

    assert image_generation_tool.check_fal_api_key() is False


def test_openai_compatible_requirements_use_image_gen_key(monkeypatch):
    from tools import image_generation_tool

    monkeypatch.setenv("IMAGE_GEN_API_KEY", "img-key")
    monkeypatch.setattr(
        image_generation_tool,
        "_load_image_gen_config",
        lambda: {
            "backend": "openai_compatible",
            "base_url": "https://sub2api.1postpro.com/v1",
            "model": "gpt-image-2",
        },
    )

    assert image_generation_tool.check_image_generation_requirements() is True
