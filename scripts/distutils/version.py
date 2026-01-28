try:
    from setuptools._distutils.version import StrictVersion  # type: ignore
except Exception:  # pragma: no cover
    from packaging.version import Version as StrictVersion  # fallback
