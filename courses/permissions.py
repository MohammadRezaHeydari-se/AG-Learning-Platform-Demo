from .roles import is_admin, is_student


def teaches_course(user, course):
    return bool(user.is_authenticated and course.teacher_id == user.id)


def is_enrolled(user, course):
    return bool(
        user.is_authenticated
        and course.enrollments.filter(student=user).exists()
    )


def user_can_access_course(user, course):
    if not user.is_authenticated:
        return False
    if is_admin(user) or teaches_course(user, course):
        return True
    return is_student(user) and is_enrolled(user, course)


def visible_lessons(user, course):
    lessons = course.lessons.all()
    if is_admin(user) or teaches_course(user, course):
        return lessons
    return lessons.filter(published=True)
