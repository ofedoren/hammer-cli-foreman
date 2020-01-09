module HammerCLIForeman
  module ComputeResources
    class Rackspace < Base
      def name
        'Rackspace'
      end

      def compute_attributes
        %w[flavor_id]
      end

      def provider_specific_fields
        super + [
          Fields::Field.new(:label => _('Region'), :path => [:region])
        ]
      end

      def mandatory_resource_options
        super + %i[url]
      end
    end

    HammerCLIForeman.register_compute_resource('rackspace', Rackspace.new)
  end
end
