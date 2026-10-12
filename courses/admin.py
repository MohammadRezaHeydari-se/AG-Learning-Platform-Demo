from django.contrib import admin

from .models import Course, Enrollment, Lesson


@admin.register(Course)
class CourseAdmin(admin.ModelAdmin):
    list_display = ('title', 'teacher', 'published')
    list_filter = ('published',)
    search_fields = ('title',)
    list_select_related = ('teacher',)


@admin.register(Enrollment)
class EnrollmentAdmin(admin.ModelAdmin):
    list_display = ('student', 'course', 'created_at')
    list_filter = ('course',)
    list_select_related = ('student', 'course')


@admin.register(Lesson)
class LessonAdmin(admin.ModelAdmin):
    list_display = ('title', 'course', 'position', 'published')
    list_filter = ('published', 'course')
    ordering = ('course', 'position')
    list_select_related = ('course',)
