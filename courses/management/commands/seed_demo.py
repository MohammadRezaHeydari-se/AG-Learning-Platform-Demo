import os

from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand

from courses.models import Course, Enrollment, Lesson
from courses.roles import STUDENT, TEACHER, ensure_role_groups

User = get_user_model()


DEMO_COURSES = [
    ("Linux Fundamentals", "Linux commands, users, permissions and system administration.", True),
    ("Docker Essentials", "Images, containers, volumes and Docker networking.", True),
    ("CI/CD with GitHub Actions", "Automated testing, builds and deployment pipelines.", True),
    ("Microsoft Azure Fundamentals", "Cloud resources, virtual machines and storage.", True),
    ("Python for DevOps", "Python scripting and automation for infrastructure.", True),
    ("Kubernetes Basics", "Pods, deployments and container orchestration.", False),
]

TEACHER_COURSES = [
    "Linux Fundamentals",
    "Docker Essentials",
    "CI/CD with GitHub Actions",
]

STUDENT_COURSES = [
    "Linux Fundamentals",
    "Docker Essentials",
]

LESSON_BLUEPRINTS = [
    ("Introduction to {topic}", "Overview and learning goals for {topic}."),
    ("Core concepts of {topic}", "Key ideas and vocabulary for {topic}."),
    ("Hands-on lab: {topic}", "Guided practice for {topic}."),
]

DEMO_PASSWORDS = {
    "admin": ("DEMO_ADMIN_PASSWORD", "demo-admin-pass"),
    "teacher": ("DEMO_TEACHER_PASSWORD", "demo-teacher-pass"),
    "student": ("DEMO_STUDENT_PASSWORD", "demo-student-pass"),
}


def demo_password(key):
    env_name, fallback = DEMO_PASSWORDS[key]
    return os.environ.get(env_name, fallback)


class Command(BaseCommand):
    help = "Create or refresh safe, fictional demo data (idempotent, never resets existing passwords)."

    def handle(self, *args, **options):
        groups = ensure_role_groups()

        admin = self._upsert_user(
            "demo_admin",
            demo_password("admin"),
            email="demo_admin@example.com",
            is_staff=True,
            is_superuser=True,
        )
        teacher = self._upsert_user(
            "demo_teacher",
            demo_password("teacher"),
            email="demo_teacher@example.com",
            group=groups[TEACHER],
        )
        student = self._upsert_user(
            "demo_student",
            demo_password("student"),
            email="demo_student@example.com",
            group=groups[STUDENT],
        )

        for title, description, published in DEMO_COURSES:
            Course.objects.update_or_create(
                title=title,
                defaults={"description": description, "published": published},
            )

        Course.objects.filter(title__in=TEACHER_COURSES).update(teacher=teacher)

        for title in STUDENT_COURSES:
            Enrollment.objects.get_or_create(
                student=student,
                course=Course.objects.get(title=title),
            )

        lesson_count = 0
        for course in Course.objects.all():
            for position, (title_tpl, content_tpl) in enumerate(LESSON_BLUEPRINTS, start=1):
                Lesson.objects.update_or_create(
                    course=course,
                    position=position,
                    defaults={
                        "title": title_tpl.format(topic=course.title),
                        "content": content_tpl.format(topic=course.title),
                        "published": True,
                    },
                )
                lesson_count += 1

        self.stdout.write(
            self.style.SUCCESS(
                "Demo data ready: "
                f"{Course.objects.count()} courses, {lesson_count} lessons, "
                f"users {admin.username}, {teacher.username}, {student.username}."
            )
        )

    def _upsert_user(self, username, password, *, email="", is_staff=False, is_superuser=False, group=None):
        user, created = User.objects.get_or_create(username=username)
        user.email = email
        user.is_staff = is_staff
        user.is_superuser = is_superuser
        # Only set the password when the account is first created so that
        # restarting the stack never resets a password changed by the user.
        if created:
            user.set_password(password)
        user.save()
        if group is not None:
            user.groups.set([group])
        return user
