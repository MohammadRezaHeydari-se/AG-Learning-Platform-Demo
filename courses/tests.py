from django.test import TestCase
from django.urls import reverse
from .models import Course

class CourseListTests(TestCase):
    def test_only_published_courses_are_visible(self):
        Course.objects.create(title='Visible', published=True)
        Course.objects.create(title='Hidden', published=False)
        response = self.client.get(reverse('course-list'))
        self.assertEqual(response.status_code, 200)
        self.assertEqual([item['title'] for item in response.json()['courses']], ['Visible'])
