hugo_version=0.134.0

build:
	docker run --rm -v `pwd`:/src --workdir /src/site hugomods/hugo:$(hugo_version) hugo

serve:
	docker run --rm -v `pwd`:/src --workdir /src/site -p 1313:1313 hugomods/hugo:$(hugo_version) hugo server --bind 0.0.0.0
