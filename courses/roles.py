from django.contrib.auth.models import Group

ADMIN = "Admin"
TEACHER = "Teacher"
STUDENT = "Student"

ROLE_GROUPS = (TEACHER, STUDENT)


def is_admin(user):
    return bool(user.is_authenticated and user.is_superuser)


def is_teacher(user):
    return bool(user.is_authenticated and user.groups.filter(name=TEACHER).exists())


def is_student(user):
    return bool(user.is_authenticated and user.groups.filter(name=STUDENT).exists())


def role_for(user):
    if is_admin(user):
        return ADMIN
    if is_teacher(user):
        return TEACHER
    if is_student(user):
        return STUDENT
    return None


def ensure_role_groups():
    groups = {}
    for name in ROLE_GROUPS:
        groups[name], _ = Group.objects.get_or_create(name=name)
    return groups
