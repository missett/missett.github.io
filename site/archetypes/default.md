---
title: "{{ replace .Name "-" " " | title }}"
date: {{ .Date }}
draft: true
build: 
    list: always
    publishResources: true
    render: always
---

