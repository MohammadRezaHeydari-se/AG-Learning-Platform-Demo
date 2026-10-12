from django.contrib.auth.decorators import login_required
from django.core.exceptions import PermissionDenied
from django.http import JsonResponse
from django.shortcuts import get_object_or_404, render

from .models import Course
from .permissions import user_can_access_course, visible_lessons
from .roles import is_admin, is_student, is_teacher, role_for


def course_list(request):
    courses = Course.objects.filter(published=True).order_by('title')
    return JsonResponse({'courses': list(courses.values('id', 'title', 'description'))})


def home(request):
    courses = Course.objects.filter(published=True).order_by('title')
    return render(request, 'courses/home.html', {'courses': courses})


@login_required
def dashboard(request):
    role = role_for(request.user)
    context = {'role': role, 'courses': Course.objects.none()}
    if is_admin(request.user):
        context['courses'] = Course.objects.order_by('title')
    elif is_teacher(request.user):
        context['courses'] = Course.objects.filter(teacher=request.user).order_by('title')
    elif is_student(request.user):
        context['courses'] = (
            Course.objects.filter(enrollments__student=request.user)
            .distinct()
            .order_by('title')
        )
    return render(request, 'courses/dashboard.html', context)


@login_required
def course_lessons(request, course_id):
    course = get_object_or_404(Course, pk=course_id)
    if not user_can_access_course(request.user, course):
        raise PermissionDenied
    lessons = visible_lessons(request.user, course)
    return render(
        request,
        'courses/course_lessons.html',
        {'course': course, 'lessons': lessons},
    )
