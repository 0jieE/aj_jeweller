from rest_framework.pagination import PageNumberPagination


class Pagination(PageNumberPagination):
    """`?page=` and `?page_size=` (default 50, at most 500)."""

    page_size_query_param = "page_size"
    max_page_size = 500
