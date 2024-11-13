require "httparty"

module LaaCrimeFormsCommon
  module Autogrant
    module LocationService
      LocationError = Class.new(StandardError)
      ResponseError = Class.new(LocationError)
      NotFoundError = Class.new(LocationError)
      InvalidFormatError = Class.new(LocationError)
      UnknowablePartialPostcode = Class.new(LocationError)

      extend self

      def inside_m25?(postcode, sql_executor)
        easting, northing = os_coordinates_from_postcode(postcode)
        query = prepare_query(easting, northing)

        result = sql_executor.execute(query)
        result.to_a.dig(0, "st_contains")
      end

    private

      def os_coordinates_from_postcode(postcode)
        canonical = postcode.delete(" ").upcase
        results = HTTParty.get("https://api.os.uk/search/names/v1/find?query=#{canonical}&key=#{ENV.fetch('OS_API_KEY', nil)}")
        process_api_response(results, canonical)
      end

      def process_api_response(payload, postcode)
        raise ResponseError, "OS API returned unexpected format when queried for postcode #{postcode}" unless payload["results"]

        matching = find_matching_result(payload, postcode)

        raise NotFoundError, "OS API returned no matching entry for postcode #{postcode}" unless matching

        easting = matching.dig("GAZETTEER_ENTRY", "GEOMETRY_X")
        northing = matching.dig("GAZETTEER_ENTRY", "GEOMETRY_Y")

        unless easting && northing
          raise InvalidFormatError, "OS API did not provide coordinates in expected format for postcode #{postcode}"
        end

        [easting, northing]
      end

      def find_matching_result(payload, postcode)
        exact_match = payload["results"].find { _1.dig("GAZETTEER_ENTRY", "ID") == postcode }

        return exact_match if exact_match

        # postcode may be an outcode. If so, and it's not an outcode that straddles the M25,
        # we can extract a representative postcode within that outcode and check if _that_
        # is inside the M25.
        if outcodes_that_straddle_the_m25.include?(postcode)
          raise UnknowablePartialPostcode, "Outcode #{postcode} could be inside or outside the M25"
        end

        payload["results"].find do |result|
          result.dig("GAZETTEER_ENTRY", "NAME1")&.split&.first == postcode &&
            result.dig("GAZETTEER_ENTRY", "LOCAL_TYPE") == "Postcode"
        end
      end

      def prepare_query(easting, northing)
        <<-SQL.freeze
          SELECT ST_Contains(
            ST_MakePolygon(
              ST_GeomFromKML('#{m25_kml}')
            ),
            ST_Transform(
              ST_GeomFromText(
                'POINT(#{easting} #{northing})',
                #{OS_SRID}
              ),
              #{STANDARD_SRID}
            )
          );
        SQL
      end

      def m25_kml
        # This KML was generated, and can be re-generated, in the following way:
        # First, use OSRM to generate a driving route in a loop round the M25 and return a granular
        # set of coordinates:
        # https://router.project-osrm.org/route/v1/driving/-0.404893,51.306192;0.267195,51.483951;-0.447781,51.684867;-0.404893,51.306192?overview=full&annotations=nodes&geometries=geojson
        # Next, use those coordinates to generate a KML file using https://kmltools.appspot.com/gps2kml
        # You can verify that KML file by uploading it to https://kmlviewer.nsspot.net/
        # Finally Postgis can only parse _part_ of the KML, so pull out the <LineString> node and everything inside it
        # and discard the rest, then save what you've kept to M25.kml
        File.read(File.join(__dir__, "M25.kml"))
      end

      def outcodes_that_straddle_the_m25
        YAML.load_file(File.join(__dir__, "outcodes_that_straddle_the_m25.yaml"))
      end

      OS_SRID = 27_700
      STANDARD_SRID = 4326
    end
  end
end
