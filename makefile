hugo_version=0.134.0

build:
	docker run --rm -v `pwd`:/src --workdir /src/site hugomods/hugo:$(hugo_version) hugo
