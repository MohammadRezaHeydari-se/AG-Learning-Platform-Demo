from django.http import JsonResponse
from .models import Course

def course_list(request):
    courses = Course.objects.filter(published=True).order_by('title')
    return JsonResponse({'courses': list(courses.values('id', 'title', 'description'))})
