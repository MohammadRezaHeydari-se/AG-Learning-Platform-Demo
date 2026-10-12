import os
import secrets
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent


def _read_secret(key_file):
    try:
        value = key_file.read_text(encoding='utf-8').strip()
        return value or None
    except OSError:
        return None


def _write_secret(key_file, value):
    """Create the key file atomically without clobbering an existing key.

    The value is written to a private temporary file (mode 0600) and then linked
    into place, so the target is never observed empty or world-readable. When
    several processes race to create the key, the first one wins and the others
    read the winner's value.
    """
    try:
        key_file.parent.mkdir(parents=True, exist_ok=True)
    except OSError:
        return
    tmp = key_file.parent / ('.%s.%d.tmp' % (key_file.name, os.getpid()))
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as handle:
            os.fchmod(handle.fileno(), 0o600)
            handle.write(value)
        try:
            os.link(tmp, key_file)
        except FileExistsError:
            pass
        except OSError:
            fd2 = os.open(key_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd2, 'w', encoding='utf-8') as handle:
                os.fchmod(handle.fileno(), 0o600)
                handle.write(value)
    except OSError:
        pass
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def _load_secret_key():
    """Return a strong SECRET_KEY with no predictable fallback.

    Preference order: the DJANGO_SECRET_KEY environment variable, then a
    persisted key file, otherwise a newly generated key written atomically to
    the file (created with mode 0600) so local sessions survive restarts. If the
    file cannot be created the generated key is used for this process only.
    """
    env_key = os.environ.get('DJANGO_SECRET_KEY', '').strip()
    if env_key:
        return env_key
    key_file = Path(os.environ.get('DJANGO_SECRET_KEY_FILE', str(BASE_DIR / '.django_secret_key')))
    persisted = _read_secret(key_file)
    if persisted:
        return persisted
    _write_secret(key_file, secrets.token_urlsafe(64))
    return _read_secret(key_file) or secrets.token_urlsafe(64)


SECRET_KEY = _load_secret_key()
DEBUG = os.environ.get('DJANGO_DEBUG', 'false').lower() == 'true'
ALLOWED_HOSTS = os.environ.get('DJANGO_ALLOWED_HOSTS', 'localhost,127.0.0.1,testserver').split(',')
INSTALLED_APPS = [
    'django.contrib.admin', 'django.contrib.auth', 'django.contrib.contenttypes',
    'django.contrib.sessions', 'django.contrib.messages', 'django.contrib.staticfiles',
    'courses',
]
MIDDLEWARE = [
    'django.middleware.security.SecurityMiddleware',
    'django.contrib.sessions.middleware.SessionMiddleware',
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
    'django.middleware.clickjacking.XFrameOptionsMiddleware',
]
ROOT_URLCONF = 'config.urls'
TEMPLATES = [{'BACKEND': 'django.template.backends.django.DjangoTemplates', 'DIRS': [], 'APP_DIRS': True, 'OPTIONS': {'context_processors': [
    'django.template.context_processors.debug', 'django.template.context_processors.request',
    'django.contrib.auth.context_processors.auth', 'django.contrib.messages.context_processors.messages',
]}}]
WSGI_APPLICATION = 'config.wsgi.application'
DATABASES = {'default': {'ENGINE': 'django.db.backends.sqlite3', 'NAME': os.environ.get('DATABASE_PATH', str(BASE_DIR / 'db.sqlite3'))}}
AUTH_PASSWORD_VALIDATORS = [{'NAME': 'django.contrib.auth.password_validation.MinimumLengthValidator'}]
LOGIN_URL = 'login'
LOGIN_REDIRECT_URL = 'dashboard'
LOGOUT_REDIRECT_URL = 'home'
LANGUAGE_CODE = 'en-us'
TIME_ZONE = 'UTC'
USE_I18N = True
USE_TZ = True
STATIC_URL = '/static/'
DEFAULT_AUTO_FIELD = 'django.db.models.BigAutoField'
