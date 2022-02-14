class MessagesUsersController < ApplicationController
    check_grant :message
    public
    def new
        @message = Message.find(params[:message_id])
        @message_status = MessageStatus.all()
        @count_message_by_stat = MessagesUser.
                                joins( :message_status ).
                                select('message_statuses.name, messages_users.message_status_id, count(messages_users.id) cnt').
                                where(message_id: @message.id).
                                group('message_statuses.name, messages_users.message_status_id').
                                map { |f| [f.name, f.cnt]}.to_h
        @message_statuses = Array.new() {Hash.new}
        sum_cnt = 0
        MessageStatus.all().each do |stat_row|
            cnt = @count_message_by_stat["#{stat_row.name}"].to_i
            sum_cnt += cnt
            @message_statuses.push(
                'name'          => stat_row.name,
                'value'         => cnt,
                "id"            => stat_row.id,
                'css_style'     => '',
                "im?"           => false,
                )
        end
        @message_statuses.push(
                'name'          => 'Всего',
                'value'         => sum_cnt,
                'id'            => -1,
                'css_style'     => 'font-weight: bold;',
                "im?"           => false,
                )
        common_rel_items = Array.new() {Hash.new}
        common_selected_ids = properties_hash @message.id
            
        # TODO: Hash.order.to_json.from_json
        # REVIEW: Почему не ordered_hash? Теоретически можно переписать сейчас. 
        # Не стала так как решили писать с помощью текущего варианта. Страницу будем переписывать на новые компоненты и тогда же сформируем новый ordered hash
        filials = OrgUnit.where( parent: nil ).order( :name )


        common_rel_items.push({ 
            'head'          => 'Филиалы',
            'rel_items'     => filials,
            'selected_ids'  => "org_unit_id",
            'user_role'     => false,
        })

        common_rel_items.push({
            'head'          => 'Курсы',
            'rel_items'     => StudCourse.joins( curriculum: [:academic_year, :qualification] ).
                                 where( 'number > 0 and current_date between start_date and end_date' ).
                                 select("stud_courses.id, stud_courses.name, stud_courses.number, string_agg(distinct qualifications.name, '\n') as title").
                                 group("stud_courses.id, stud_courses.name, stud_courses.number").
                                 distinct.
                                 order(:number),
            'selected_ids'  => "stud_course_id",
            'user_role'     => false,
        })
        common_rel_items.push({
            'head'          => 'Роли',
            'rel_items'     => Grant.where("name LIKE '[Role grants]%'").order( :name ),
            'selected_ids'  => "grant_id",
            'user_role'     => true,
        })
        common_rel_items.push({
            'head'          => 'Формы обучения',
            'rel_items'     => EduForm.all().order( :name ),
            'selected_ids'  => "edu_form_id",
            'user_role'     => false,
        })
        common_rel_items.push({
            'head'          => 'Формы финансирования',
            'rel_items'     => FinForm.all().order( :name ),
            'selected_ids'  => "fin_form_id",
            'user_role'     => false,
        })
        message_all_settings = Property.joins(:property_class).where( property_classes: { code: 'NEWS' } ).where( "properties.message_id is null or properties.message_id = #{@message.id}" )
        qualification_settings = message_all_settings.where.not(qualification_id: nil).select('properties.*').map{|f| f.qualification_id}
        common_rel_items.push({
            'head'          => 'Квалификации',
            'rel_items'     => Qualification.order( :name ),
            'selected_ids'  => "qualification_id",
            'subset_items'  => Qualification.where( id: qualification_settings ).order( :name ),
            'user_role'     => false,
        })
        org_unit_type_settings = message_all_settings.where.not(org_unit_type_id: nil).select('properties.*').map{|f| f.org_unit_type_id}
        filials.each do |filial|
            common_rel_items.push({
                'head'          => 'Подразделения ' + filial.name,
                'rel_items'     => OrgUnit.where(org_unit_type_id: org_unit_type_settings).where.not(parent: nil).where("portal.org_unit_root_id(org_units.id) = #{filial.id}").order( :name ),
                'selected_ids'  => "org_unit_id",
                'user_role'     => false,
            })
        end

        @data =  {
            index_path:                 'messages_users_path',
            rel_items_name:             'messages_users_ids',
            ':rel_selected_item_ids'    => [].to_json,
            ':item'                     => {id: @message.id, name: "Отправка новости", code: "ID: #{@message.id}"}.to_json,
            ':filter_tags'              => [].to_json,
            ':common_rel_items'         => common_rel_items.to_json,
            ':common_selected_ids'      => common_selected_ids.to_json,
        }

        if (not common_selected_ids.empty? and sum_cnt == 0)
            flash[:error] = 'По выбранным параметрам пользователи не найдены'
        end

    end

    #PUT messages_users/:message_id
    def update
        ActiveRecord::Base.transaction do
            property_class = PropertyClass.find_by( code: 'NEWS' ).id
            selected_ids = filter_params[:common_selected_ids]

            message_id = filter_params[:item_id]
            message = "Не задан message_id"
            message_type = "error"
            if message_id
                # собираем hash массивов значений текущих параметров отправки
                # Общий вид:
                # {"column1_name" => [column1_value1, column1_value2, ..., column1_valueN],
                #  "column2_name" => [column2_value1, column2_value2, ..., column2_valueN],
                #
                #  ...
                #
                #  "columnM_name" => [columnM_value1, columnM_value2, ..., columnM_valueN]"}
                # 
                old_properties = properties_hash message_id
                # Цикл по hash
                old_properties.each do |property|
                    # Внутри цикла property = ["columnM_name", [columnM_value1, columnM_value2, ..., columnM_valueN]]
                    column_name = property.first
                    value_array = property.last

                    # Находим массив раницы между старыми свойствами и новыми
                    diff = value_array - selected_ids[column_name]
                    # Удаляем
                    if not diff.empty?
                        @message_properties.where("properties.#{property.first} in (#{diff.join(',')})").delete_all
                    end

                    # Находим массив раницы между новыми свойствами и старыми
                    diff = selected_ids[column_name] - value_array
                    # Добавляем строки в таблицу properties
                    diff.each do |insert_row|
                        Property.create( description: 'NEWS', domain: 'MESSAGE', property_class_id: property_class, message_id: message_id, "#{property.first}": insert_row )                    
                    end
                end
                # Удалить все направленные сообщения
                MessagesUser.where(message_id: message_id).delete_all

                new_person = ActiveRecord::Base.connection.execute 'select pseudo_message_user_properties( ' + message_id.to_s + ' )'
                
                message_type_id = Message.find(message_id).message_type_id
                message_status_noread_id = MessageStatus.noread.id
             
                connection = ActiveRecord::Base.connection

                columns = [:person_id, :message_id, :message_type_id, :message_status_id].join(',')
                values = (new_person).map { |person_id| 
                    "(#{[person_id['pseudo_message_user_properties'], message_id, message_type_id, message_status_noread_id].join(',')})"
                }.join(',')
                # Отправить сообщения заново

                connection.execute("INSERT INTO messages_users (#{columns}) VALUES #{values}") if values.length > 0
                count_message_user = MessagesUser.where(message_id: message_id).count
                message = "Новость направлена " + count_message_user.to_s
                message_type = "success"
            end
            flash[:success] = message
            render json: {items: selected_ids}.to_json          
        end   
    rescue Coder::Exception => e
        e.log
        flash[:error] = e.message
    end

    #DELETE messages_users/:message_id
    def destroy
        message_id = params[:id]
        MessagesUser.where(message_id: message_id).delete_all
        message_id_properties message_id
        @message_properties.delete_all
        flash[:success] = "Сообщение сейчас не направляется никому"

    end
    def readed
        message_id = params[:message_id]
        person_id = current_user.person_id
        message_user = MessagesUser.find_by(message_id: message_id, person_id: person_id)
        message_user.readed  #прочитано обработка в моделе Message User
        render json: "OK".to_json
    end

    private
    def message_id_properties message_id
        @message_properties = Property.joins(:property_class).where( properties: {message_id: message_id}, property_classes: { code: 'NEWS' } ).select('properties.*')
    end
    
    def properties_hash message_id
        common_selected_ids = Hash.new
        property_columns = ["qualification_id", "edu_form_id", "fin_form_id", "stud_course_id","org_unit_id", "grant_id" ]
        property_columns.each do |col|
            common_selected_ids[col] = []
        end
            
        message_id_properties message_id
        properties_map = @message_properties.map{|f| {"id" => f.id, 
                    "message_id"        => f.message_id,
                    "qualification_id"  => f.qualification_id,
                    "edu_form_id"       => f.edu_form_id,
                    "fin_form_id"       => f.fin_form_id,
                    "stud_course_id"    => f.stud_course_id,
                    "org_unit_id"       => f.org_unit_id,
                    "grant_id"          => f.grant_id,
                     }} 

        properties_map.each do |row|
            property_columns.each do |col|
                common_selected_ids[col].push row[col] if row[col] != nil
            end
        end
        return common_selected_ids
    end
    def filter_params
        params.require(:item).permit(:item_id, :common_selected_ids=>{})
    end
      
    
end
