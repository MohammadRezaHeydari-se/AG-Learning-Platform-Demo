from io import StringIO

from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.test import TestCase
from django.urls import reverse

from .models import Course, Enrollment, Lesson
from .roles import ADMIN, STUDENT, TEACHER, ensure_role_groups, role_for

User = get_user_model()
PASSWORD = "test-password-123"


class CourseListTests(TestCase):
    def test_only_published_courses_are_visible(self):
        Course.objects.create(title="Visible", published=True)
        Course.objects.create(title="Hidden", published=False)
        response = self.client.get(reverse("course-list"))
        self.assertEqual(response.status_code, 200)
        self.assertEqual([item["title"] for item in response.json()["courses"]], ["Visible"])


class SeedDemoTests(TestCase):
    def test_seed_creates_six_courses_and_is_idempotent(self):
        call_command("seed_demo", stdout=StringIO())
        self.assertEqual(Course.objects.count(), 6)
        self.assertEqual(Course.objects.filter(published=True).count(), 5)
        call_command("seed_demo", stdout=StringIO())
        self.assertEqual(Course.objects.count(), 6)

    def test_seed_courses_visible_in_api(self):
        call_command("seed_demo", stdout=StringIO())
        response = self.client.get(reverse("course-list"))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(response.json()["courses"]), 5)

    def test_seed_creates_demo_users_lessons_and_enrollments(self):
        call_command("seed_demo", stdout=StringIO())
        teacher = User.objects.get(username="demo_teacher")
        student = User.objects.get(username="demo_student")
        self.assertTrue(User.objects.filter(username="demo_admin", is_superuser=True).exists())
        self.assertTrue(teacher.groups.filter(name=TEACHER).exists())
        self.assertTrue(student.groups.filter(name=STUDENT).exists())
        self.assertEqual(Course.objects.filter(teacher=teacher).count(), 3)
        self.assertEqual(Enrollment.objects.filter(student=student).count(), 2)
        self.assertEqual(Lesson.objects.count(), 6 * 3)

    def test_seed_full_dataset_is_idempotent(self):
        call_command("seed_demo", stdout=StringIO())
        counts = (User.objects.count(), Course.objects.count(), Lesson.objects.count(), Enrollment.objects.count())
        call_command("seed_demo", stdout=StringIO())
        self.assertEqual(
            (User.objects.count(), Course.objects.count(), Lesson.objects.count(), Enrollment.objects.count()),
            counts,
        )

    def test_seed_does_not_reset_existing_passwords(self):
        call_command("seed_demo", stdout=StringIO())
        user = User.objects.get(username="demo_student")
        user.set_password("changed-by-user-456")
        user.save()
        call_command("seed_demo", stdout=StringIO())
        user.refresh_from_db()
        self.assertTrue(user.check_password("changed-by-user-456"))
        self.assertFalse(user.check_password("demo-student-pass"))


class RoleTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        cls.groups = ensure_role_groups()

    def test_role_for_returns_expected_role(self):
        admin = User.objects.create_superuser("admin", email="admin@example.com", password=PASSWORD)
        teacher = self._role_user("teacher", TEACHER)
        student = self._role_user("student", STUDENT)
        self.assertEqual(role_for(admin), ADMIN)
        self.assertEqual(role_for(teacher), TEACHER)
        self.assertEqual(role_for(student), STUDENT)

    def _role_user(self, username, group_name):
        user = User.objects.create_user(username, password=PASSWORD)
        user.groups.add(self.groups[group_name])
        return user

    def test_user_without_role_has_none(self):
        user = User.objects.create_user("plain", password=PASSWORD)
        self.assertIsNone(role_for(user))

    def test_anonymous_user_has_no_role(self):
        from django.contrib.auth.models import AnonymousUser

        self.assertIsNone(role_for(AnonymousUser()))


class AuthenticationTests(TestCase):
    def test_home_page_is_public(self):
        response = self.client.get(reverse("home"))
        self.assertEqual(response.status_code, 200)

    def test_home_lists_only_published_courses(self):
        Course.objects.create(title="Visible", published=True)
        Course.objects.create(title="Hidden", published=False)
        response = self.client.get(reverse("home"))
        self.assertContains(response, "Visible")
        self.assertNotContains(response, "Hidden")

    def test_dashboard_requires_login(self):
        response = self.client.get(reverse("dashboard"))
        self.assertRedirects(response, f"{reverse('login')}?next={reverse('dashboard')}")

    def test_login_view_authenticates_and_redirects(self):
        User.objects.create_user("student", password=PASSWORD)
        response = self.client.post(
            reverse("login"),
            {"username": "student", "password": PASSWORD},
        )
        self.assertRedirects(response, reverse("dashboard"))

    def test_logout_view_clears_session(self):
        User.objects.create_user("student", password=PASSWORD)
        self.client.login(username="student", password=PASSWORD)
        response = self.client.post(reverse("logout"))
        self.assertRedirects(response, reverse("home"))
        self.assertEqual(self.client.get(reverse("dashboard")).status_code, 302)

    def test_logout_requires_post(self):
        User.objects.create_user("student", password=PASSWORD)
        self.client.login(username="student", password=PASSWORD)
        self.assertEqual(self.client.get(reverse("logout")).status_code, 405)


class LessonPermissionTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        cls.groups = ensure_role_groups()
        cls.course = Course.objects.create(title="Linux", published=True)
        cls.other_course = Course.objects.create(title="Other", published=True)
        cls.published_lesson = Lesson.objects.create(
            course=cls.course, title="Intro", position=1, published=True
        )
        cls.hidden_lesson = Lesson.objects.create(
            course=cls.course, title="Hidden", position=2, published=False
        )
        cls.teacher = User.objects.create_user("teacher", password=PASSWORD)
        cls.teacher.groups.add(cls.groups[TEACHER])
        cls.course.teacher = cls.teacher
        cls.course.save(update_fields=["teacher"])
        cls.other_teacher = User.objects.create_user("teacher2", password=PASSWORD)
        cls.other_teacher.groups.add(cls.groups[TEACHER])
        cls.student = User.objects.create_user("student", password=PASSWORD)
        cls.student.groups.add(cls.groups[STUDENT])
        Enrollment.objects.create(student=cls.student, course=cls.course)
        cls.stranger = User.objects.create_user("stranger", password=PASSWORD)
        cls.stranger.groups.add(cls.groups[STUDENT])
        cls.admin = User.objects.create_superuser(
            "admin", email="admin@example.com", password=PASSWORD
        )

    def lessons_url(self, course):
        return reverse("course-lessons", kwargs={"course_id": course.id})

    def test_anonymous_redirected_to_login(self):
        response = self.client.get(self.lessons_url(self.course))
        self.assertEqual(response.status_code, 302)
        self.assertIn(reverse("login"), response.url)

    def test_teacher_can_access_own_course_and_sees_unpublished(self):
        self.client.login(username="teacher", password=PASSWORD)
        response = self.client.get(self.lessons_url(self.course))
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, "Hidden")

    def test_teacher_cannot_access_other_teacher_course(self):
        self.client.login(username="teacher2", password=PASSWORD)
        response = self.client.get(self.lessons_url(self.course))
        self.assertEqual(response.status_code, 403)

    def test_enrolled_student_sees_only_published_lessons(self):
        self.client.login(username="student", password=PASSWORD)
        response = self.client.get(self.lessons_url(self.course))
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, "Intro")
        self.assertNotContains(response, "Hidden")

    def test_unenrolled_student_is_denied(self):
        self.client.login(username="stranger", password=PASSWORD)
        response = self.client.get(self.lessons_url(self.course))
        self.assertEqual(response.status_code, 403)

    def test_admin_can_access_any_course(self):
        self.client.login(username="admin", password=PASSWORD)
        response = self.client.get(self.lessons_url(self.other_course))
        self.assertEqual(response.status_code, 200)

    def test_dashboard_lists_courses_per_role(self):
        self.client.login(username="student", password=PASSWORD)
        response = self.client.get(reverse("dashboard"))
        self.assertContains(response, "Linux")
        self.assertNotContains(response, "Other")

    def test_teacher_dashboard_lists_taught_courses(self):
        self.client.login(username="teacher", password=PASSWORD)
        response = self.client.get(reverse("dashboard"))
        self.assertContains(response, "Linux")
        self.assertNotContains(response, "Other")
