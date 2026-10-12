from django.db import models

class Course(models.Model):
    title = models.CharField(max_length=160)
    description = models.TextField(blank=True)
    published = models.BooleanField(default=False)

    def __str__(self):
        return self.title
