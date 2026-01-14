
/*
 * Copyright (C) Zhu Jiashun
 * Copyright (C) Zaver
 */

#ifndef HTTP_REQUEST_H
#define HTTP_REQUEST_H

#include <errno.h>
#include <stddef.h>
#include <time.h>
#include <sys/types.h>
#include "list.h"
#include "util.h"

#define ZV_AGAIN    EAGAIN

#define ZV_HTTP_PARSE_INVALID_METHOD        10
#define ZV_HTTP_PARSE_INVALID_REQUEST       11
#define ZV_HTTP_PARSE_INVALID_HEADER        12

#define ZV_HTTP_UNKNOWN                     0x0001
#define ZV_HTTP_GET                         0x0002
#define ZV_HTTP_HEAD                        0x0004
#define ZV_HTTP_POST                        0x0008

#define ZV_HTTP_OK                          200

#define ZV_HTTP_NOT_MODIFIED                304

#define ZV_HTTP_NOT_FOUND                   404

#define MAX_BUF 8124

/* output buffer sizes (avoid depending on http.h to prevent circular includes) */
#define ZV_OUT_HEADER_SIZE 8192

typedef struct zv_http_request_s {
    void *root;
    int fd;
    int epfd;
    char buf[MAX_BUF];  /* ring buffer */
    /*
     * Buffer normalization (sliding window): buf[0..last) is always contiguous.
     * parse_pos is the parser cursor used for incremental parsing (ZV_AGAIN).
     */
    size_t last;
    size_t parse_pos;
    int request_line_state;
    int header_state;
    int parse_phase; /* 0: request line, 1: headers, 2: ready to handle */
    void *request_start;
    void *method_end;   /* not include method_end*/
    int method;
    void *uri_start;
    void *uri_end;      /* not include uri_end*/ 
    void *path_start;
    void *path_end;
    void *query_start;
    void *query_end;
    int http_major;
    int http_minor;
    void *request_end;

    struct list_head list;  /* store http header */
    void *cur_header_key_start;
    void *cur_header_key_end;
    void *cur_header_value_start;
    void *cur_header_value_end;

    void *timer;

    /* timeouts (ms) copied from config at init */
    size_t keep_alive_timeout_ms;
    size_t request_timeout_ms;

    /* output state for non-blocking write continuation */
    int keep_alive;                 /* for current response */
    int writing;                    /* 1 when waiting EPOLLOUT to continue */
    char out_header[ZV_OUT_HEADER_SIZE];
    size_t out_header_len;
    size_t out_header_sent;
    char *out_body;                 /* optional heap buffer for error page */
    size_t out_body_len;
    size_t out_body_sent;
    int out_file_fd;                /* optional file fd for sendfile */
    off_t out_file_offset;
    size_t out_file_size;

    /* freelist link (used only when caching zv_http_request_t) */
    struct list_head freelist;

    /* epoll items for watched fds (connection + optional CGI pipes) */
    struct zv_ep_item_s *conn_item;
    struct zv_ep_item_s *cgi_out_item;
    struct zv_ep_item_s *cgi_in_item;

    /* CGI state (minimal MVP: GET only, connection is closed after response) */
    int cgi_active; //让 do_write() 知道“这是 CGI 响应”，走 zv_cgi_on_client_writable() 而不是静态 try_send()
    pid_t cgi_pid; //用于超时/关闭连接时 kill + waitpid 回收。
    int cgi_in_fd;     //父进程写 CGI 输入的 fd（GET MVP 不用，设为 -1）。
    int cgi_out_fd;   //父进程读 CGI 输出的 fd。
    int cgi_eof;    
    size_t cgi_out_total;
    size_t cgi_out_limit;

    int cgi_headers_done; //标志 CGI 响应头是否已经完整读完。
    char cgi_hdr_buf[4096];// CGI 响应头缓冲区
    size_t cgi_hdr_len;// 已读到缓冲区的字节数

    char cgi_http_header[4096];// CGI 生成的 HTTP 响应头发送缓冲区
    size_t cgi_http_header_len;// CGI 生成的 HTTP 响应头长度
    size_t cgi_http_header_sent;// CGI 生成的 HTTP 响应头已发送字节数

    /* chunked transfer encoding state for CGI streaming */
    char cgi_chunk_prefix[32]; // 每个 chunk 前缀缓冲区（格式：<chunk-size>\r\n）
    size_t cgi_chunk_prefix_len;// 前缀长度
    size_t cgi_chunk_prefix_sent;// 已发送前缀字节数
    size_t cgi_chunk_suffix_sent; //后缀\r\n已发送字节数
    char cgi_final_chunk[8];      /* "0\r\n\r\n" */
    size_t cgi_final_chunk_len;
    size_t cgi_final_chunk_sent;

    char cgi_body_buf[8192];    // CGI 输出正文缓冲区
    size_t cgi_body_len;        // 正文字节数
    size_t cgi_body_sent;       // 已发送正文字节数
} zv_http_request_t;

typedef struct {
    int fd;
    int keep_alive;
    time_t mtime;       /* the modified time of the file*/
    int modified;       /* compare If-modified-since field with mtime to decide whether the file is modified since last time*/

    int status;
} zv_http_out_t;

typedef struct zv_http_header_s {
    void *key_start, *key_end;          /* not include end */
    void *value_start, *value_end;
    list_head list;
} zv_http_header_t;

typedef int (*zv_http_header_handler_pt)(zv_http_request_t *r, zv_http_out_t *o, char *data, int len);

typedef struct {
    char *name;
    zv_http_header_handler_pt handler;
} zv_http_header_handle_t;

void zv_http_handle_header(zv_http_request_t *r, zv_http_out_t *o);
int zv_http_close_conn(zv_http_request_t *r);

int zv_init_request_t(zv_http_request_t *r, int fd, int epfd, zv_conf_t *cf);
int zv_free_request_t(zv_http_request_t *r);

int zv_init_out_t(zv_http_out_t *o, int fd);
int zv_free_out_t(zv_http_out_t *o);

const char *get_shortmsg_from_status_code(int status_code);

extern zv_http_header_handle_t     zv_http_headers_in[];

#endif
 
